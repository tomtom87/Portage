require "bigdecimal"

module UcpMcp
  module Shopify
    # Generic UcpMcp::Adapter over standard Shopify catalog/cart/checkout/
    # order primitives (roadmap step 4) — no merchant-specific business
    # logic. A merchant with bespoke checkout semantics (subscriptions,
    # bundles, whatever) writes their own Adapter on top of the same
    # contract, same as anyone on any other backend would (§7.1).
    #
    # Deliberately doesn't override `link_identity`: Shopify's OAuth identity
    # story lives in the separate Customer Account API, out of scope for
    # this generic adapter (see roadmap step 4's explicit "catalog/cart/
    # checkout/order only"). Leaving it un-overridden means Capability#
    # advertised_for? simply doesn't advertise dev.ucp.shopping.identity for
    # this adapter — not a 500, just an absent capability.
    #
    # Catalog and Order are read through the Admin API (Storefront can't
    # look up an arbitrary order without a customer session). Cart and
    # Checkout are read/written through the Storefront API's Cart object —
    # Admin has no "Cart"; a headless checkout is a Storefront Cart plus its
    # `checkoutUrl` payment/completion mutations, not a separate Checkout
    # object. UCP's create_checkout/update_checkout/complete_checkout are
    # threaded onto that one underlying Cart id.
    class Adapter < UcpMcp::Adapter
      def initialize(client:)
        super()
        @client = client
        # §9a: mutating Adapter methods must dedup by idempotency_key so an
        # agent's retry on a dropped connection can't double-charge. Neither
        # Storefront cart mutations nor cartPaymentUpdate take an idempotency
        # key natively (cartSubmitForCompletion's attemptId is the one
        # exception — see #complete_checkout), so this adapter keeps its own
        # in-process dedup table rather than relying on the API.
        @idempotency_results = {}
      end

      def search_catalog(query:, limit:)
        data = @client.admin_query(Queries::SEARCH_CATALOG, variables: { query: query, first: limit })
        data.dig("products", "nodes").map { |node| Mapper.product(node) }
      end

      def get_product(product_id:)
        data = @client.admin_query(Queries::GET_PRODUCT, variables: { id: product_id })
        node = data["product"]
        node && Mapper.product(node)
      end

      def get_cart(cart_id:)
        data = @client.storefront_query(Queries::GET_CART, variables: { id: cart_id })
        cart_node = data["cart"]
        cart_node && Mapper.cart(cart_node)
      end

      def add_line_item(cart_id:, product_id:, quantity:, idempotency_key:)
        dedup(idempotency_key) do
          line = { merchandiseId: product_id, quantity: quantity }
          data = @client.storefront_query(Queries::CART_LINES_ADD, variables: { cartId: cart_id, lines: [line] })
          Mapper.cart(unwrap!(data, "cartLinesAdd"))
        end
      end

      def remove_line_item(cart_id:, line_item_id:, idempotency_key:)
        dedup(idempotency_key) do
          data = @client.storefront_query(Queries::CART_LINES_REMOVE, variables: { cartId: cart_id,
                                                                                   lineIds: [line_item_id] })
          Mapper.cart(unwrap!(data, "cartLinesRemove"))
        end
      end

      def create_checkout(line_items:, idempotency_key:)
        dedup(idempotency_key) do
          lines = line_items.map { |li| { merchandiseId: li.product_id, quantity: li.quantity } }
          data = @client.storefront_query(Queries::CART_CREATE, variables: { input: { lines: lines } })
          Mapper.checkout(unwrap!(data, "cartCreate"), status: "pending")
        end
      end

      def update_checkout(checkout_id:, updates:, idempotency_key:)
        dedup(idempotency_key) do
          data = @client.storefront_query(Queries::CART_BUYER_IDENTITY_UPDATE,
                                          variables: { cartId: checkout_id, buyerIdentity: updates })
          Mapper.checkout(unwrap!(data, "cartBuyerIdentityUpdate"), status: "pending")
        end
      end

      # `payment_token` is the single-use tokenized credential from a UCP
      # payment handler (already validated as non-PAN by PaymentTokenGuard
      # before this is ever called, per §9). It's threaded straight into
      # Storefront's `cartPaymentUpdate` as a vaulted single-use token — the
      # exact `paymentMethod` sub-shape is payment-handler-specific per
      # Shopify's docs and needs confirming against a real dev store
      # (roadmap step 5); this passes the token through rather than guessing
      # a shape that only a live handler negotiation can pin down.
      def complete_checkout(checkout_id:, payment_token:, idempotency_key:)
        dedup(idempotency_key) { submit_payment(checkout_id, payment_token, idempotency_key) }
      end

      def get_order(order_id:)
        data = @client.admin_query(Queries::GET_ORDER, variables: { id: order_id })
        node = data["order"]
        node && Mapper.order(node)
      end

      private

      # Reuses idempotency_key as cartSubmitForCompletion's own attemptId too
      # — Shopify natively dedups that one call via SubmitAlreadyAccepted, on
      # top of #complete_checkout's own dedup wrapper.
      def submit_payment(checkout_id, payment_token, idempotency_key)
        cart_data = @client.storefront_query(Queries::GET_CART, variables: { id: checkout_id })
        cart_node = cart_data.fetch("cart") { raise UcpMcp::Shopify::Error, "cart #{checkout_id} not found" }
        total = cart_node.dig("cost", "totalAmount")

        payment_data = @client.storefront_query(
          Queries::CART_PAYMENT_UPDATE,
          variables: { cartId: checkout_id,
                       payment: { totalAmount: total,
                                  singleUseTokenPayment: { paymentAmount: total, singleUseToken: payment_token } } }
        )
        unwrap!(payment_data, "cartPaymentUpdate")

        submit_data = @client.storefront_query(Queries::CART_SUBMIT_FOR_COMPLETION,
                                               variables: { cartId: checkout_id, attemptToken: idempotency_key })
        Mapper.checkout(cart_node, status: unwrap_submit!(submit_data))
      end

      def dedup(idempotency_key)
        return @idempotency_results[idempotency_key] if @idempotency_results.key?(idempotency_key)

        @idempotency_results[idempotency_key] = yield
      end

      def unwrap!(data, field)
        payload = data.fetch(field)
        errors = payload["userErrors"]
        raise UcpMcp::Shopify::UserError.new(field, errors) if errors && !errors.empty?

        payload.fetch("cart")
      end

      def unwrap_submit!(data)
        payload = data.fetch("cartSubmitForCompletion")
        errors = payload["userErrors"]
        raise UcpMcp::Shopify::UserError.new("cartSubmitForCompletion", errors) if errors && !errors.empty?

        result = payload["result"]
        raise UcpMcp::Shopify::Error, result.dig("errors", 0, "message") if result["errors"]

        result.key?("pollAfter") ? "pending" : "completed"
      end
    end
  end
end
