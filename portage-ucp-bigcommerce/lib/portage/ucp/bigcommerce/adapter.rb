require "uri"

module Portage
  module Ucp
    module BigCommerce
      # Generic Portage::Ucp::Adapter over a BigCommerce store's v3 Catalog/
      # Carts/Checkouts APIs and v2 Orders API — no merchant-specific
      # business logic, same posture as Portage::Ucp::Shopify::Adapter and
      # Portage::Ucp::WooCommerce::Adapter.
      #
      # Deliberately doesn't override `link_identity`: BigCommerce's storefront
      # customer login (JWT-based Customer Login API) is a separate concern
      # from the store-owner API account this gem uses, so this generic
      # adapter leaves it unimplemented — Capability#advertised_for? simply
      # won't advertise dev.ucp.shopping.identity for this adapter, not a 500.
      #
      # Catalog and Order are read through the Admin API (v3 and v2
      # respectively — Orders has never moved off v2). Cart and Checkout are
      # read/written through the v3 Carts/Checkouts APIs: unlike Shopify/
      # WooCommerce, BigCommerce's Checkout *is* a distinct resource from its
      # Cart, but shares the same id — creating a Cart implicitly creates its
      # matching Checkout.
      #
      # IMPORTANT CAVEAT: #complete_checkout creates an order from the
      # checkout, mints a single-order Payment Access Token, then submits
      # `payment_token` as a tokenized instrument to the separate Payments
      # API (`payments.bigcommerce.com`). The exact `payment_instrument`
      # shape a given payment gateway expects hasn't been confirmed against
      # a live store with a real gateway installed — same "needs confirming
      # against a live store" posture as Portage::Ucp::Shopify::Adapter and
      # Portage::Ucp::WooCommerce::Adapter's own payment steps.
      class Adapter < Portage::Ucp::Adapter
        # Neither the Carts nor the Checkouts API takes an idempotency key
        # natively, so §9a dedup comes from Support::Idempotency's in-process
        # table.
        include Portage::Ucp::Support::Idempotency
        # BigCommerce's Checkout has no native status field of its own, and
        # v2 Orders don't link back to the Checkout that produced them —
        # both are tracked adapter-side via Support::CheckoutState, keyed by
        # the shared cart/checkout id.
        include Portage::Ucp::Support::CheckoutState
        # The v3 and v2 APIs both answer a missing resource with a 404 rather
        # than an empty body, which UCP's reads report as nil.
        include Portage::Ucp::Support::NotFound

        def initialize(client:, site_url:, currency:, payment_gateway_id: nil)
          super()
          @client = client
          @site_url = site_url.chomp("/")
          @currency = currency
          @payment_gateway_id = payment_gateway_id
        end

        def search_catalog(query:, limit:)
          path = "/catalog/products?keyword=#{URI.encode_www_form_component(query)}&limit=#{limit}&include=variants"
          @client.v3_get(path)["data"].map { |node| Mapper.product(node, currency: @currency, site_url: @site_url) }
        end

        def get_product(product_id:)
          nil_on_not_found do
            node = @client.v3_get("/catalog/products/#{product_id}?include=variants")["data"]
            node && Mapper.product(node, currency: @currency, site_url: @site_url)
          end
        end

        def get_cart(cart_id:)
          nil_on_not_found do
            node = fetch_cart_node(cart_id)
            node && Mapper.cart(node, id: cart_id)
          end
        end

        def create_cart(line_items:, idempotency_key:)
          dedup(idempotency_key) do
            node = @client.v3_post("/carts", { line_items: cart_lines(line_items) })["data"]
            Mapper.cart(node, id: node["id"])
          end
        end

        # Full replacement, matching UCP's real cart semantics: the Carts API
        # has no atomic "replace all lines" endpoint either. New lines are
        # added *before* the old ones are removed — BigCommerce auto-deletes
        # the whole cart when its last remaining line item is removed, so
        # removing old lines first (when the desired list is non-empty)
        # would destroy the cart this call is supposed to be updating.
        def update_cart(cart_id:, line_items:, idempotency_key:)
          dedup(idempotency_key) { Mapper.cart(replace_cart_lines(cart_id, line_items), id: cart_id) }
        end

        # Unlike Shopify (no cancellation mutation at all) and WooCommerce
        # (only a session cart to clear), BigCommerce's Carts API supports
        # deleting the cart resource outright — the closest real equivalent
        # to cancellation available on any of the three. The returned Cart
        # reflects that the resource is now gone (empty line_items, no
        # currency) rather than raising: schema-valid, just not information-
        # complete, same posture as
        # Portage::Ucp::Shopify::Adapter#link_cart_to_order's best-effort miss.
        def cancel_cart(cart_id:, idempotency_key:)
          dedup(idempotency_key) do
            delete_cart(cart_id)
            Mapper.cart({}, id: cart_id)
          end
        end

        def create_checkout(line_items:, idempotency_key:)
          dedup(idempotency_key) do
            cart_node = @client.v3_post("/carts", { line_items: cart_lines(line_items) })["data"]
            record_checkout_status(cart_node["id"], "incomplete")
            Mapper.checkout(fetch_checkout_node(cart_node["id"]), id: cart_node["id"], status: "incomplete")
          end
        end

        def get_checkout(checkout_id:)
          nil_on_not_found do
            node = fetch_checkout_node(checkout_id)
            node && Mapper.checkout(node, id: checkout_id, status: checkout_status(checkout_id))
          end
        end

        # Full replacement, same rationale as #update_cart — BigCommerce's
        # Checkout shares its underlying cart with #update_cart.
        def update_checkout(checkout_id:, line_items:, idempotency_key:)
          dedup(idempotency_key) do
            replace_cart_lines(checkout_id, line_items)
            record_checkout_status(checkout_id, "incomplete")
            Mapper.checkout(fetch_checkout_node(checkout_id), id: checkout_id, status: "incomplete")
          end
        end

        def complete_checkout(checkout_id:, payment_token:, idempotency_key:)
          dedup(idempotency_key) { submit_checkout(checkout_id, payment_token) }
        end

        # The Checkouts API has no cancellation endpoint for an in-progress
        # checkout either (see #cancel_cart's contrast) — this just marks the
        # tracked status canceled without touching the underlying cart.
        def cancel_checkout(checkout_id:, idempotency_key:)
          dedup(idempotency_key) do
            record_checkout_status(checkout_id, "canceled")
            Mapper.checkout(fetch_checkout_node(checkout_id), id: checkout_id, status: "canceled")
          end
        end

        def get_order(order_id:)
          nil_on_not_found do
            node = @client.v2_get("/orders/#{order_id}")
            next nil unless node["id"]

            products = @client.v2_get("/orders/#{order_id}/products")
            Mapper.order(node, products: products, site_url: @site_url,
                               checkout_id: checkout_id_for(order_id))
          end
        end

        private

        def fetch_cart_node(cart_id)
          include_param = "line_items.physical_items.options,line_items.digital_items.options"
          @client.v3_get("/carts/#{cart_id}?include=#{include_param}")["data"]
        end

        def fetch_checkout_node(checkout_id)
          @client.v3_get("/checkouts/#{checkout_id}")["data"]
        end

        def delete_cart(cart_id)
          nil_on_not_found { @client.v3_delete("/carts/#{cart_id}") }
        end

        # Maps a UCP line item request straight to `{product_id, quantity}`.
        # A real variant-level add needs `{product_id, variant_id}` together
        # — this generic adapter, same as
        # Portage::Ucp::WooCommerce::Adapter#cart_lines, assumes the given id
        # already identifies the exact sellable unit and doesn't attempt to
        # split it back into a product/variant pair.
        def cart_lines(line_items)
          line_items.map { |li| { product_id: li[:product_id].to_i, quantity: li[:quantity] } }
        end

        def cart_item_ids(node)
          ((node.dig("line_items", "physical_items") || []) + (node.dig("line_items", "digital_items") || []))
            .map { |item| item["id"] }
        end

        def replace_cart_lines(cart_id, line_items)
          current_item_ids = cart_item_ids(fetch_cart_node(cart_id))
          @client.v3_post("/carts/#{cart_id}/items", { line_items: cart_lines(line_items) }) unless line_items.empty?
          current_item_ids.each { |item_id| @client.v3_delete("/carts/#{cart_id}/items/#{item_id}") }
          return {} if line_items.empty?

          fetch_cart_node(cart_id)
        end

        # See the class-level CAVEAT: `payment_instrument` uses a single
        # configurable gateway id (`payment_gateway_id:`) rather than a
        # confirmed gateway-specific instrument shape.
        def submit_checkout(checkout_id, payment_token)
          unless @payment_gateway_id
            raise Portage::Ucp::BigCommerce::Error,
                  "no payment_gateway_id configured on this Adapter"
          end

          checkout_node = fetch_checkout_node(checkout_id)
          order_id = @client.v3_post("/checkouts/#{checkout_id}/orders", {}).dig("data", "id")
          access_token = @client.v3_post("/payments/access_tokens", { order: { id: order_id } }).dig("data", "id")
          @client.process_payment(payment_access_token: access_token, order_id: order_id,
                                  payment_instrument: { type: "tokenized_instrument", token: payment_token,
                                                        gateway: @payment_gateway_id })

          record_checkout_status(checkout_id, "completed")
          record_order_checkout(order_id, checkout_id)
          Mapper.checkout(checkout_node, id: checkout_id, status: "completed", order: order_confirmation(order_id))
        end

        # Same order-status URL pattern as Mapper.order's `permalink_url`.
        def order_confirmation(order_id)
          Portage::Ucp::OrderConfirmation.new(
            id: order_id.to_s, permalink_url: "#{@site_url}/account.php?action=order_status&order_id=#{order_id}"
          )
        end
      end
    end
  end
end
