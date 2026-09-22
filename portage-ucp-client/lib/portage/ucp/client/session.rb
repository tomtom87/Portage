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
                              complete_checkout cancel_checkout create_payment_enrollment].freeze

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

        # `context:` is the UCP `context` object — buyer locale hints
        # (`address_country`, `address_region`, `postal_code`, `currency`,
        # `language`). Optional on paper, effectively required against a real
        # store: see Transports::Http#with_context for what a store does with
        # a cart built without one. Ignored by the loopback/stdio transports,
        # which talk to this gem's own flat-argument server.
        def search_catalog(query:, limit: 20, context: nil,
                           meta: nil)
          call("search_catalog", meta: meta, query: query, limit: limit, context: context)
        end

        def get_product(product_id:, context: nil, meta: nil)
          call("get_product", meta: meta, product_id: product_id, context: context)
        end

        def lookup_catalog(product_ids:, context: nil, meta: nil)
          call("lookup_catalog", meta: meta, product_ids: product_ids, context: context)
        end

        def get_cart(cart_id:, meta: nil) = call("get_cart", meta: meta, cart_id: cart_id)

        def create_cart(line_items:, idempotency_key: nil, context: nil, meta: nil)
          call("create_cart", meta: meta, line_items: line_items, idempotency_key: idempotency_key,
                              context: context)
        end

        def update_cart(cart_id:, line_items:, idempotency_key: nil, context: nil, meta: nil)
          call("update_cart", meta: meta, cart_id: cart_id, line_items: line_items,
                              idempotency_key: idempotency_key, context: context)
        end

        def cancel_cart(cart_id:, idempotency_key: nil, meta: nil)
          call("cancel_cart", meta: meta, cart_id: cart_id, idempotency_key: idempotency_key)
        end

        # `fulfillment:` (dev.ucp.shopping.fulfillment) is only exercised over
        # the loopback transport today (Portage::Cli::Buy's own-store adapter
        # path) — passed straight through as whatever value the caller built
        # (a Portage::Ucp::CheckoutFulfillment for loopback). Over stdio/HTTP
        # it would need a JSON wire shape this gem doesn't build yet, so
        # callers on those transports should leave it nil.
        # `cart_id:` converts an existing cart into a checkout rather than
        # re-listing its contents from scratch — HTTP only (see
        # Transports::Http#wrap_line_items); `line_items:` stays required
        # because the live server rejects a `cart_id`-only body.
        def create_checkout(line_items:, idempotency_key: nil, fulfillment: nil, cart_id: nil, context: nil,
                            meta: nil)
          call("create_checkout", meta: meta, line_items: line_items, idempotency_key: idempotency_key,
                                  context: context, **(cart_id ? { cart_id: cart_id } : {}),
                                  **(fulfillment ? { fulfillment: fulfillment } : {}))
        end

        def get_checkout(checkout_id:, meta: nil) = call("get_checkout", meta: meta, checkout_id: checkout_id)

        def update_checkout(checkout_id:, line_items:, idempotency_key: nil, fulfillment: nil, context: nil,
                            meta: nil)
          call("update_checkout", meta: meta, checkout_id: checkout_id, line_items: line_items,
                                  idempotency_key: idempotency_key, context: context,
                                  **(fulfillment ? { fulfillment: fulfillment } : {}))
        end

        def complete_checkout(checkout_id:, payment_token:, idempotency_key: nil, meta: nil)
          Portage::Ucp::PaymentTokenGuard.validate!(payment_token)
          call("complete_checkout", meta: meta, checkout_id: checkout_id, payment_token: payment_token,
                                    idempotency_key: idempotency_key)
        end

        def cancel_checkout(checkout_id:, idempotency_key: nil, meta: nil)
          call("cancel_checkout", meta: meta, checkout_id: checkout_id, idempotency_key: idempotency_key)
        end

        def get_order(order_id:, meta: nil) = call("get_order", meta: meta, order_id: order_id)
        def link_identity(oauth_token:, meta: nil) = call("link_identity", meta: meta, oauth_token: oauth_token)

        # app.portage-ucp.payment_enrollment (Portage extension, §ref
        # docs/plans/agentic-payments.md Phase 1) — not every adapter
        # advertises this, check #advertises? first.
        def create_payment_enrollment(idempotency_key: nil, meta: nil)
          call("create_payment_enrollment", meta: meta, idempotency_key: idempotency_key)
        end

        def get_payment_enrollment(enrollment_id:, meta: nil)
          call("get_payment_enrollment", meta: meta, enrollment_id: enrollment_id)
        end

        private

        def call(action, meta: nil, **arguments)
          arguments.delete(:context) if arguments[:context].nil?
          arguments[:idempotency_key] ||= SecureRandom.uuid if MUTATING_ACTIONS.include?(action)
          @transport.call_tool(name: action, arguments: arguments, meta: meta)
        end
      end
    end
  end
end
