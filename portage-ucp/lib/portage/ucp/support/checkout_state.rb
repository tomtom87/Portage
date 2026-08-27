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
        # Dispatcher wraps each adapter call in .with_observability rather
        # than writing [logger, correlation_id] onto an instance variable on
        # the adapter. The adapter instance is shared across every session in
        # the process (built once in Mcp::Server.build), so an instance
        # variable is a race: two concurrent requests against the same
        # adapter clobber each other's correlation id, and
        # checkout_state_transition ends up stamped with the wrong request's
        # id — the same per-process-state trap §23 diagnosed for the
        # correlation id generator itself, one layer down. Storage is
        # Thread.current, keyed by the adapter's object_id so multiple
        # adapters (e.g. in specs) don't share a slot, and .with_observability
        # restores whatever was there before on the way out so a stale value
        # never leaks into an unrelated direct adapter call afterward.
        #
        # A `correlation_id:` kwarg on every checkout method would carry the
        # same information, but those methods are the public Adapter
        # contract (§9), and adding a required kwarg there breaks any
        # existing adapter/caller (§23) — this stays out of that contract.
        def self.with_observability(adapter, logger, correlation_id)
          key = observability_key(adapter)
          previous = Thread.current[key]
          Thread.current[key] = [logger, correlation_id]
          yield
        ensure
          Thread.current[key] = previous
        end

        def self.observability_key(adapter)
          :"portage_ucp_checkout_state_observability_#{adapter.object_id}"
        end

        private

        def checkout_status(checkout_id)
          (@checkout_status ||= {}).fetch(checkout_id, "incomplete")
        end

        def record_checkout_status(checkout_id, status)
          (@checkout_status ||= {})[checkout_id] = status
          log_checkout_transition(checkout_id, status)
        end

        def log_checkout_transition(checkout_id, status)
          logger, correlation_id = Thread.current[CheckoutState.observability_key(self)]
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
