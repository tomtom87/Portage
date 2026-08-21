require "bigdecimal"

module Portage
  module Ucp
    module Shopify
      # Generic Portage::Ucp::Adapter over standard Shopify catalog/cart/checkout/
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
      class Adapter < Portage::Ucp::Adapter
        # Neither Storefront cart mutations nor cartPaymentUpdate take an
        # idempotency key natively — cartSubmitForCompletion's attemptId is
        # the one exception, see #submit_payment — so §9a dedup comes from
        # Support::Idempotency's in-process table.
        include Portage::Ucp::Support::Idempotency
        # Shopify's Cart has no native "checkout status" field (Checkout is
        # modeled as the same underlying Cart), and its Order has no field
        # back to the cart that produced it — both are tracked adapter-side
        # via Support::CheckoutState.
        include Portage::Ucp::Support::CheckoutState

        def initialize(client:)
          super()
          @client = client
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
            record_checkout_status(cart_node["id"], "incomplete")
            Mapper.checkout(cart_node, status: "incomplete")
          end
        end

        def get_checkout(checkout_id:)
          cart_node = fetch_cart_node(checkout_id)
          cart_node && Mapper.checkout(cart_node, status: checkout_status(checkout_id))
        end

        # Full replacement, same rationale as #update_cart — Shopify checkout
        # *is* the cart object.
        def update_checkout(checkout_id:, line_items:, idempotency_key:)
          dedup(idempotency_key) do
            cart_node = replace_lines(checkout_id, line_items)
            record_checkout_status(checkout_id, "incomplete")
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
            record_checkout_status(checkout_id, "canceled")
            cart_node = fetch_cart_node(checkout_id)
            Mapper.checkout(cart_node, status: "canceled")
          end
        end

        def get_order(order_id:)
          data = @client.admin_query(Queries::GET_ORDER, variables: { id: order_id })
          node = data["order"]
          node && Mapper.order(node, checkout_id: checkout_id_for(order_id))
        end

        # orderCancel returns only a (possibly still-pending) job — the
        # updated cancellation state is read back via #get_order, same
        # "trust a fresh read over the mutation payload" posture as
        # #cancel_checkout.
        def cancel_order(order_id:, idempotency_key:, reason: nil)
          dedup(idempotency_key) do
            data = @client.admin_query(Queries::ORDER_CANCEL, variables: { orderId: order_id, staffNote: reason })
            raise_on_errors!(data, "orderCancel", "orderCancelUserErrors")
            get_order(order_id: order_id)
          end
        end

        # `line_items:` here are order line items ({id:, quantity:}) — the
        # same ids GET_ORDER's line_items carry — since refundLineItems keys
        # off the plain LineItem id, unlike request_return's
        # fulfillmentLineItemId below.
        def refund_order(order_id:, line_items:, idempotency_key:, reason: nil)
          dedup(idempotency_key) do
            refund_line_items = line_items.map { |li| { lineItemId: li[:id], quantity: li[:quantity] } }
            transactions = suggested_refund_transactions(order_id, refund_line_items)
            data = @client.admin_query(
              Queries::REFUND_CREATE,
              variables: { input: { orderId: order_id, note: reason, refundLineItems: refund_line_items,
                                    transactions: transactions } }
            )
            raise_on_errors!(data, "refundCreate", "userErrors")
            get_order(order_id: order_id)
          end
        end

        def request_return(order_id:, line_items:, idempotency_key:, reason: nil)
          dedup(idempotency_key) do
            return_line_items = line_items.map do |li|
              { fulfillmentLineItemId: li[:id], quantity: li[:quantity], returnReason: "OTHER",
                returnReasonNote: reason }
            end
            data = @client.admin_query(Queries::RETURN_CREATE,
                                       variables: { returnInput: { orderId: order_id,
                                                                   returnLineItems: return_line_items } })
            raise_on_errors!(data, "returnCreate", "userErrors")
            get_order(order_id: order_id)
          end
        end

        private

        def raise_on_errors!(data, field, errors_key)
          errors = data.dig(field, errors_key)
          raise Portage::Ucp::Shopify::UserError.new(field, errors) if errors && !errors.empty?
        end

        def suggested_refund_transactions(order_id, refund_line_items)
          data = @client.admin_query(Queries::SUGGESTED_REFUND,
                                     variables: { orderId: order_id, refundLineItems: refund_line_items })
          (data.dig("order", "suggestedRefund", "transactions") || []).map do |t|
            { orderId: order_id, gateway: t["gateway"], kind: t["kind"],
              amount: t.dig("amountSet", "shopMoney", "amount"), parentId: t.dig("parentTransaction", "id") }
          end
        end

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
          cart_node = fetch_cart_node(checkout_id)
          raise Portage::Ucp::Shopify::Error, "cart #{checkout_id} not found" unless cart_node

          raise_if_any_line_unavailable!(cart_node)

          pay_for_cart(checkout_id, cart_node.dig("cost", "totalAmount"), payment_token)

          submit_data = @client.storefront_query(Queries::CART_SUBMIT_FOR_COMPLETION,
                                                 variables: { cartId: checkout_id, attemptToken: idempotency_key })
          status = unwrap_submit!(submit_data)
          record_checkout_status(checkout_id, status)
          order = link_cart_to_order(checkout_id) if status == "completed"
          Mapper.checkout(cart_node, status: status, order: order)
        end

        def pay_for_cart(checkout_id, total, payment_token)
          payment_data = @client.storefront_query(
            Queries::CART_PAYMENT_UPDATE,
            variables: { cartId: checkout_id,
                         payment: { totalAmount: total,
                                    singleUseTokenPayment: { paymentAmount: total, singleUseToken: payment_token } } }
          )
          unwrap!(payment_data, "cartPaymentUpdate")
        end

        # Best-effort: if `status` is `complete_in_progress` (SubmitThrottled),
        # the order doesn't exist yet, so there's nothing to look up — a poller
        # calling #get_checkout again later would need to retry this too, which
        # this adapter doesn't do on its own. If the order search index hasn't
        # caught up yet even for a synchronously-completed cart, this silently
        # finds nothing (returns nil, #get_order's checkout_id stays blank)
        # rather than raising, matching the "not information-complete but
        # schema-valid" posture used elsewhere in this file. Also the only
        # place that can hand the freshly-created order id back to
        # #complete_checkout's own caller — nothing else surfaces it.
        def link_cart_to_order(checkout_id)
          token = checkout_id[%r{Cart/([^?]+)}, 1]
          return unless token

          data = @client.admin_query(Queries::ORDER_BY_CART_TOKEN, variables: { query: "cart_token:#{token}" })
          order_node = data.dig("orders", "nodes", 0)
          return unless order_node

          record_order_checkout(order_node["id"], checkout_id)
          Portage::Ucp::OrderConfirmation.new(id: order_node["id"], permalink_url: order_node["statusPageUrl"])
        end

        def unwrap!(data, field)
          payload = data.fetch(field)
          errors = payload["userErrors"]
          raise Portage::Ucp::Shopify::UserError.new(field, errors) if errors && !errors.empty?

          payload.fetch("cart")
        end

        # Checked against a live dev store: a sold-out line doesn't get its
        # own SubmissionErrorCode on cartSubmitForCompletion — Shopify raises
        # the same NO_DELIVERY_GROUP_SELECTED code it uses for an ordinary
        # incomplete checkout that simply hasn't picked a delivery option yet,
        # so a code-substring match on that mutation's errors can't tell stale
        # stock apart from a normal in-progress checkout. availableForSale on
        # each line's merchandise is the one field that actually flips when a
        # variant goes out of stock, so the check happens here instead, before
        # a payment is even attempted.
        def raise_if_any_line_unavailable!(cart_node)
          unavailable = cart_node.dig("lines", "nodes").reject { |n| n.dig("merchandise", "availableForSale") }
          return if unavailable.empty?

          titles = unavailable.map { |n| n.dig("merchandise", "product", "title") }.join(", ")
          raise Portage::Ucp::OutOfStockError, "no longer available: #{titles}"
        end

        def unwrap_submit!(data)
          payload = data.fetch("cartSubmitForCompletion")
          errors = payload["userErrors"]
          raise Portage::Ucp::Shopify::UserError.new("cartSubmitForCompletion", errors) if errors && !errors.empty?

          result = payload["result"]
          raise Portage::Ucp::Shopify::Error, result.dig("errors", 0, "message") if result["errors"]

          result.key?("pollAfter") ? "complete_in_progress" : "completed"
        end
      end
    end
  end
end
