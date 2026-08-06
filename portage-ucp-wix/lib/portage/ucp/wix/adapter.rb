require "json"

module Portage
  module Ucp
    module Wix
      # Generic Portage::Ucp::Adapter over Wix's Stores (catalog) and
      # eCommerce (cart/checkout/order) REST APIs — no merchant-specific
      # business logic, same posture as Portage::Ucp::Shopify::Adapter.
      #
      # Deliberately doesn't override `link_identity`: Wix's OAuth identity
      # story (Wix Members/visitor auth) is a separate concern from the
      # site-level app auth this gem uses for catalog/cart/checkout/order, so
      # this generic adapter leaves it unimplemented — Capability#
      # advertised_for? simply won't advertise dev.ucp.shopping.identity for
      # this adapter, not a 500.
      #
      # Unlike Shopify, where Cart and Checkout are the same underlying
      # object, Wix models them as genuinely separate resources with their
      # own REST endpoints — so, unlike Shopify's Adapter, there's no shared
      # create_cart_node/create_checkout_node plumbing between the two.
      #
      # IMPORTANT CAVEAT: #complete_checkout's call to Wix's "Create Order"
      # endpoint hasn't been confirmed against a live site. Wix's documented
      # checkout flow expects payment to already be authorized through a
      # payment provider (Wix Payments or a connected PSP) before an order
      # is created — there's no confirmed equivalent of Shopify's
      # cartPaymentUpdate that accepts an arbitrary single-use payment_token
      # directly. `payment_token` is accepted for interface parity with the
      # other Portage::Ucp adapters but isn't currently sent anywhere; wiring
      # real payment capture needs confirming against a live Wix site with a
      # configured payment provider before this method is production-ready.
      class Adapter < Portage::Ucp::Adapter
        # Wix's fixed app id for its own Stores catalog, required on every
        # cart/checkout line item's catalogReference so Wix knows which
        # catalog `catalogItemId` belongs to.
        STORES_APP_ID = "215238eb-22a5-4c36-9e7b-e7c08025e04e".freeze

        # Wix's cart/checkout REST endpoints don't take an idempotency key
        # natively, so §9a dedup comes from Support::Idempotency's in-process
        # table.
        include Portage::Ucp::Support::Idempotency
        # Wix Checkout has no confirmed native status field, so status is
        # tracked adapter-side via Support::CheckoutState. Only the status
        # half is used here: unlike Shopify and WooCommerce, a Wix Order
        # carries its originating `checkoutId` natively (see #get_order).
        include Portage::Ucp::Support::CheckoutState

        def initialize(client:)
          super()
          @client = client
        end

        def search_catalog(query:, limit:)
          body = { query: { filter: JSON.generate({ name: { "$contains" => query } }), paging: { limit: limit } } }
          data = @client.post("/stores/v1/products/query", body)
          (data["products"] || []).map { |node| Mapper.product(node) }
        end

        def get_product(product_id:)
          node = @client.get("/stores/v1/products/#{product_id}")["product"]
          node && Mapper.product(node)
        end

        def get_cart(cart_id:)
          node = fetch_cart_node(cart_id)
          node && Mapper.cart(node)
        end

        def create_cart(line_items:, idempotency_key:)
          dedup(idempotency_key) { Mapper.cart(create_cart_node(line_items)) }
        end

        # Full replacement, matching UCP's real cart semantics: this removes
        # every current line then adds the desired ones back, same as
        # Portage::Ucp::Shopify::Adapter#update_cart (Wix's add/remove-line-
        # items endpoints aren't an atomic "replace all lines" either).
        def update_cart(cart_id:, line_items:, idempotency_key:)
          dedup(idempotency_key) { Mapper.cart(replace_cart_lines(cart_id, line_items)) }
        end

        # Wix carts can actually be deleted (unlike Shopify's, which just
        # expire) — this deletes the cart, then returns its last-known state
        # since there's nothing more to hand back once it's gone.
        def cancel_cart(cart_id:, idempotency_key:)
          dedup(idempotency_key) do
            node = fetch_cart_node(cart_id)
            @client.delete("/ecom/v1/carts/#{cart_id}")
            Mapper.cart(node)
          end
        end

        def create_checkout(line_items:, idempotency_key:)
          dedup(idempotency_key) do
            node = create_checkout_node(line_items)
            record_checkout_status(node["id"], "incomplete")
            Mapper.checkout(node, status: "incomplete")
          end
        end

        def get_checkout(checkout_id:)
          node = fetch_checkout_node(checkout_id)
          node && Mapper.checkout(node, status: checkout_status(checkout_id))
        end

        # Full replacement, same rationale as #update_cart.
        def update_checkout(checkout_id:, line_items:, idempotency_key:)
          dedup(idempotency_key) do
            node = @client.patch("/ecom/v1/checkouts/#{checkout_id}", { lineItems: cart_lines(line_items) })["checkout"]
            record_checkout_status(checkout_id, "incomplete")
            Mapper.checkout(node, status: "incomplete")
          end
        end

        # See the class-level CAVEAT: payment_token isn't currently sent to
        # Wix — see this method's implementation note below.
        def complete_checkout(checkout_id:, payment_token:, idempotency_key:)
          dedup(idempotency_key) { submit_order(checkout_id, payment_token) }
        end

        def cancel_checkout(checkout_id:, idempotency_key:)
          dedup(idempotency_key) do
            record_checkout_status(checkout_id, "canceled")
            node = fetch_checkout_node(checkout_id)
            Mapper.checkout(node, status: "canceled")
          end
        end

        # `checkout_id` comes straight off the Wix Order's own `checkoutId`
        # field — unlike Shopify, Wix's Order object links back to its
        # originating Checkout natively, so there's no cart_token-style
        # reconciliation search needed here.
        def get_order(order_id:)
          node = @client.get("/ecom/v1/orders/#{order_id}")["order"]
          node && Mapper.order(node)
        end

        private

        def fetch_cart_node(cart_id)
          @client.get("/ecom/v1/carts/#{cart_id}")["cart"]
        end

        def fetch_checkout_node(checkout_id)
          @client.get("/ecom/v1/checkouts/#{checkout_id}")["checkout"]
        end

        def cart_lines(line_items)
          line_items.map do |li|
            { catalogReference: { catalogItemId: li[:product_id], appId: STORES_APP_ID },
              quantity: li[:quantity] }
          end
        end

        def create_cart_node(line_items)
          @client.post("/ecom/v1/carts", { lineItems: cart_lines(line_items) })["cart"]
        end

        def create_checkout_node(line_items)
          @client.post("/ecom/v1/checkouts", { lineItems: cart_lines(line_items) })["checkout"]
        end

        def replace_cart_lines(cart_id, line_items)
          current_ids = fetch_cart_node(cart_id)["lineItems"].map { |n| n["id"] }
          unless current_ids.empty?
            @client.post("/ecom/v1/carts/#{cart_id}/remove-line-items", { lineItemIds: current_ids })
          end
          return fetch_cart_node(cart_id) if line_items.empty?

          @client.post("/ecom/v1/carts/#{cart_id}/add-line-items", { lineItems: cart_lines(line_items) })["cart"]
        end

        # `payment_token` is deliberately not sent anywhere yet — see the
        # class-level CAVEAT. `create-order` is called bare; a checkout that
        # hasn't actually been paid through a real Wix payment provider will
        # be rejected by Wix itself here, surfacing as an ApiError rather
        # than silently succeeding.
        def submit_order(checkout_id, _payment_token)
          node = fetch_checkout_node(checkout_id)
          raise Portage::Ucp::Wix::Error, "checkout #{checkout_id} not found" unless node

          data = @client.post("/ecom/v1/checkouts/#{checkout_id}/create-order", {})
          order_id = data["orderId"]
          status = order_id ? "completed" : "complete_in_progress"
          record_checkout_status(checkout_id, status)
          # Same "not information-complete but schema-valid" posture as
          # Mapper.order's own blank permalink_url — Wix's create-order
          # response has no storefront order-status link to hand back.
          order = order_id && Portage::Ucp::OrderConfirmation.new(id: order_id, permalink_url: "")
          Mapper.checkout(node, status: status, order: order)
        end
      end
    end
  end
end
