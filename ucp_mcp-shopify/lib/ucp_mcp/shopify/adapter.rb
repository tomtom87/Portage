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
        # Shopify's Cart has no native "checkout status" field — Checkout is
        # modeled as the same underlying Cart, so status is tracked here
        # across the create/update/complete/cancel lifecycle, keyed by cart id.
        @checkout_status = {}
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
        cart_node = fetch_cart_node(cart_id)
        cart_node && Mapper.cart(cart_node)
      end

      def create_cart(line_items:, idempotency_key:)
        dedup(idempotency_key) { Mapper.cart(create_cart_node(line_items)) }
      end

      # Full replacement, matching UCP's real cart semantics: Storefront has
      # no atomic "replace all lines" mutation, so this removes every current
      # line then adds the desired ones back (two Storefront calls).
      def update_cart(cart_id:, line_items:, idempotency_key:)
        dedup(idempotency_key) { Mapper.cart(replace_lines(cart_id, line_items)) }
      end

      # Shopify has no cart-cancellation mutation — carts simply expire.
      # Returns the cart unchanged; there's nothing more accurate to do here
      # against the real API.
      def cancel_cart(cart_id:, idempotency_key:)
        dedup(idempotency_key) { get_cart(cart_id: cart_id) }
      end

      def create_checkout(line_items:, idempotency_key:)
        dedup(idempotency_key) do
          cart_node = create_cart_node(line_items)
          @checkout_status[cart_node["id"]] = "incomplete"
          Mapper.checkout(cart_node, status: "incomplete")
        end
      end

      def get_checkout(checkout_id:)
        cart_node = fetch_cart_node(checkout_id)
        cart_node && Mapper.checkout(cart_node, status: @checkout_status.fetch(checkout_id, "incomplete"))
      end

      # Full replacement, same rationale as #update_cart — Shopify checkout
      # *is* the cart object.
      def update_checkout(checkout_id:, line_items:, idempotency_key:)
        dedup(idempotency_key) do
          cart_node = replace_lines(checkout_id, line_items)
          @checkout_status[checkout_id] = "incomplete"
          Mapper.checkout(cart_node, status: "incomplete")
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

      def cancel_checkout(checkout_id:, idempotency_key:)
        dedup(idempotency_key) do
          @checkout_status[checkout_id] = "canceled"
          cart_node = fetch_cart_node(checkout_id)
          Mapper.checkout(cart_node, status: "canceled")
        end
      end

      def get_order(order_id:)
        data = @client.admin_query(Queries::GET_ORDER, variables: { id: order_id })
        node = data["order"]
        node && Mapper.order(node)
      end

      private

      def fetch_cart_node(cart_id)
        @client.storefront_query(Queries::GET_CART, variables: { id: cart_id })["cart"]
      end

      def cart_lines(line_items)
        line_items.map { |li| { merchandiseId: li[:product_id], quantity: li[:quantity] } }
      end

      def create_cart_node(line_items)
        data = @client.storefront_query(Queries::CART_CREATE, variables: { input: { lines: cart_lines(line_items) } })
        unwrap!(data, "cartCreate")
      end

      def replace_lines(cart_id, line_items)
        current_line_ids = fetch_cart_node(cart_id).dig("lines", "nodes").map { |n| n["id"] }
        unless current_line_ids.empty?
          removed = @client.storefront_query(Queries::CART_LINES_REMOVE,
                                             variables: { cartId: cart_id, lineIds: current_line_ids })
          unwrap!(removed, "cartLinesRemove")
        end
        return fetch_cart_node(cart_id) if line_items.empty?

        added = @client.storefront_query(Queries::CART_LINES_ADD,
                                         variables: { cartId: cart_id, lines: cart_lines(line_items) })
        unwrap!(added, "cartLinesAdd")
      end

      # Reuses idempotency_key as cartSubmitForCompletion's own attemptId too
      # — Shopify natively dedups that one call via SubmitAlreadyAccepted, on
      # top of #complete_checkout's own dedup wrapper.
      def submit_payment(checkout_id, payment_token, idempotency_key)
        cart_node = fetch_cart_node(checkout_id) || (raise UcpMcp::Shopify::Error, "cart #{checkout_id} not found")
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
        status = unwrap_submit!(submit_data)
        @checkout_status[checkout_id] = status
        Mapper.checkout(cart_node, status: status)
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

        result.key?("pollAfter") ? "complete_in_progress" : "completed"
      end
    end
  end
end
