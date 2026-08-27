module Portage
  module Ucp
    module Support
      # Adapter-side bookkeeping for the two things UCP's schemas require but
      # most commerce APIs don't model:
      #
      # - Checkout#status. Shopify, WooCommerce and BigCommerce all treat a
      #   checkout as the cart (or as the cart plus billing data), with no
      #   lifecycle enum of its own, so the adapter tracks status itself
      #   across create/update/complete/cancel.
      # - Order#checkout_id. Nothing on those platforms' Order links back to
      #   the cart/checkout that produced it, so the adapter records the pair
      #   at completion time — the only moment both ids are in hand.
      #
      # Both default rather than raise on an unknown id ("incomplete" and "",
      # respectively): a checkout this process didn't create is still
      # schema-valid to report, just not information-complete.
      module CheckoutState
        # Set by Dispatcher immediately before each adapter call, never by the
        # adapter itself — [logger, correlation_id], mirroring the pair
        # `Mcp::Server` already threads through `Observability.log` calls.
        # A `correlation_id:` kwarg on every checkout method would carry the
        # same information, but those methods are the public Adapter
        # contract (§9), and adding a required kwarg there breaks any
        # existing adapter/caller (§23) — an attr_writer only Dispatcher
        # touches avoids that.
        attr_writer :ucp_observability

        private

        def checkout_status(checkout_id)
          (@checkout_status ||= {}).fetch(checkout_id, "incomplete")
        end

        def record_checkout_status(checkout_id, status)
          (@checkout_status ||= {})[checkout_id] = status
          log_checkout_transition(checkout_id, status)
        end

        def log_checkout_transition(checkout_id, status)
          logger, correlation_id = @ucp_observability
          return unless logger

          Portage::Ucp::Observability.log(logger, "checkout_state_transition", checkout_id: checkout_id,
                                                                               status: status,
                                                                               correlation_id: correlation_id)
        end

        # Keyed by String: adapters are called with an order id straight off
        # a JSON body, which is an Integer on some platforms and a String on
        # others depending on the call path.
        def record_order_checkout(order_id, checkout_id)
          (@order_checkout_ids ||= {})[order_id.to_s] = checkout_id
        end

        def checkout_id_for(order_id)
          (@order_checkout_ids ||= {}).fetch(order_id.to_s, "")
        end
      end
    end
  end
end
