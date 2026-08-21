require "securerandom"

module Portage
  module Ucp
    module Client
      # Caller-facing object returned by Client.for_adapter/.connect/.discover
      # — same convenience method names as the merchant-side
      # Portage::Ucp::Adapter, regardless of which transport is underneath
      # (loopback/stdio/HTTP; callers never know which they got).
      #
      # Generates an `idempotency_key` per mutating call unless the caller
      # supplies one, and runs PaymentTokenGuard client-side before a
      # payment_token goes out over complete_checkout — belt-and-suspenders
      # with the merchant's own guard (§9), not a replacement for it.
      #
      # A Checkout/Order response with `status == "requires_escalation"` is
      # returned normally, with its `links`, not raised as an error — callers
      # must branch on it themselves.
      class Session
        MUTATING_ACTIONS = %w[create_cart update_cart cancel_cart create_checkout update_checkout
                              complete_checkout cancel_checkout].freeze

        # @param capabilities [Array<String>, nil] reverse-domain capability
        #   names advertised by the server, when known upfront (Client.discover
        #   populates this from the manifest; Client.for_adapter/.connect leave
        #   it nil since nothing was fetched to populate it from).
        def initialize(transport:, capabilities: nil)
          @transport = transport
          @capabilities = capabilities
        end

        attr_reader :capabilities

        # @return [Boolean, nil] nil when capabilities weren't known upfront
        #   (see #capabilities) — callers with a nil result can't tell either
        #   way and should just attempt the call.
        def advertises?(capability_name)
          capabilities&.include?(capability_name)
        end

        def search_catalog(query:, limit: 20) = call("search_catalog", query: query, limit: limit)
        def get_product(product_id:) = call("get_product", product_id: product_id)

        def get_cart(cart_id:) = call("get_cart", cart_id: cart_id)

        def create_cart(line_items:, idempotency_key: nil)
          call("create_cart", line_items: line_items, idempotency_key: idempotency_key)
        end

        def update_cart(cart_id:, line_items:, idempotency_key: nil)
          call("update_cart", cart_id: cart_id, line_items: line_items, idempotency_key: idempotency_key)
        end

        def cancel_cart(cart_id:, idempotency_key: nil)
          call("cancel_cart", cart_id: cart_id, idempotency_key: idempotency_key)
        end

        # `fulfillment:` (dev.ucp.shopping.fulfillment) is only exercised over
        # the loopback transport today (Portage::Cli::Buy's own-store adapter
        # path) — passed straight through as whatever value the caller built
        # (a Portage::Ucp::CheckoutFulfillment for loopback). Over stdio/HTTP
        # it would need a JSON wire shape this gem doesn't build yet, so
        # callers on those transports should leave it nil.
        def create_checkout(line_items:, idempotency_key: nil, fulfillment: nil)
          call("create_checkout", line_items: line_items, idempotency_key: idempotency_key,
                                  **(fulfillment ? { fulfillment: fulfillment } : {}))
        end

        def get_checkout(checkout_id:) = call("get_checkout", checkout_id: checkout_id)

        def update_checkout(checkout_id:, line_items:, idempotency_key: nil, fulfillment: nil)
          call("update_checkout", checkout_id: checkout_id, line_items: line_items, idempotency_key: idempotency_key,
                                  **(fulfillment ? { fulfillment: fulfillment } : {}))
        end

        def complete_checkout(checkout_id:, payment_token:, idempotency_key: nil)
          Portage::Ucp::PaymentTokenGuard.validate!(payment_token)
          call("complete_checkout", checkout_id: checkout_id, payment_token: payment_token,
                                    idempotency_key: idempotency_key)
        end

        def cancel_checkout(checkout_id:, idempotency_key: nil)
          call("cancel_checkout", checkout_id: checkout_id, idempotency_key: idempotency_key)
        end

        def get_order(order_id:) = call("get_order", order_id: order_id)
        def link_identity(oauth_token:) = call("link_identity", oauth_token: oauth_token)

        private

        def call(action, **arguments)
          arguments[:idempotency_key] ||= SecureRandom.uuid if MUTATING_ACTIONS.include?(action)
          @transport.call_tool(name: action, arguments: arguments)
        end
      end
    end
  end
end
