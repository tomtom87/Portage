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
        private

        def checkout_status(checkout_id)
          (@checkout_status ||= {}).fetch(checkout_id, "incomplete")
        end

        def record_checkout_status(checkout_id, status)
          (@checkout_status ||= {})[checkout_id] = status
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
