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
      # schema-valid to report, just not information-complete. An adapter
      # can add a platform lookup for the unknown-id case (see
      # #platform_order).
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

        # A checkout this process has no record of falls back to the
        # platform: `portage orders reconcile` runs in a new process, after
        # the shopper paid in their browser, and the in-process hash alone
        # would always say "incomplete" there (design-log §55). See
        # #platform_order.
        def checkout_status(checkout_id)
          recorded = (@checkout_status ||= {})[checkout_id]
          return recorded if recorded

          platform_order(checkout_id) ? "completed" : "incomplete"
        end

        # The order_confirmation for a checkout #platform_order found an order
        # for, nil otherwise (an in-process #complete_checkout hands its own
        # back directly).
        def checkout_order(checkout_id)
          order = (@platform_orders ||= {})[checkout_id]
          order && Portage::Ucp::OrderConfirmation.new(id: order.id, permalink_url: order.permalink_url)
        end

        # For a #get_checkout whose cart read came back not-found: most
        # platforms drop the cart once it becomes an order (BigCommerce
        # deletes it on payment, Magento deactivates the quote), so a paid
        # checkout would otherwise only ever read as not-found. This builds
        # the completed Checkout from the order the platform reports for it.
        # No order means nil: a vanished cart on its own is never read as a
        # completion (docs/plans/handoff-reconcile.md, "Settle only on a
        # `completed` status the store actually reports").
        def checkout_from_platform_order(checkout_id)
          order = platform_order(checkout_id)
          return nil unless order

          line_items = order.line_items.map do |li|
            Portage::Ucp::LineItem.new(id: li.id, item: li.item, quantity: li.quantity[:total], totals: li.totals)
          end
          Portage::Ucp::Checkout.new(id: checkout_id, status: "completed", line_items: line_items,
                                     currency: order.currency, totals: order.totals, links: [],
                                     order: checkout_order(checkout_id))
        end

        # The optional per-adapter hook: an adapter that can ask its platform
        # "did this checkout become a placed order?" defines a private
        # `platform_checkout_order(checkout_id)` returning that Portage::Ucp::
        # Order, or nil. Without the hook (or when this process already
        # tracks the checkout) nothing changes. A found order is cached
        # through #record_checkout_status/#record_order_checkout so the rest
        # of this process agrees with it. A lookup error is swallowed: the
        # caller gets today's in-process answer, which reconcile reads as
        # "still pending", never as a settle. The hook is a private method
        # rather than a new Adapter method or kwarg for the same §9/§23
        # reason as .with_observability above.
        def platform_order(checkout_id)
          orders = (@platform_orders ||= {})
          return orders[checkout_id] if orders.key?(checkout_id)

          order = ask_platform(checkout_id)
          return nil unless order

          orders[checkout_id] = order
          record_order_checkout(order.id, checkout_id)
          record_checkout_status(checkout_id, "completed")
          order
        end

        def ask_platform(checkout_id)
          return nil if (@checkout_status ||= {}).key?(checkout_id)
          return nil unless respond_to?(:platform_checkout_order, true)

          platform_checkout_order(checkout_id)
        rescue StandardError
          nil
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
