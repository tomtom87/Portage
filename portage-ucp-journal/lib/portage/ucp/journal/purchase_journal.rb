require "time"

module Portage
  module Ucp
    module Journal
      # Buyer-side, append-only record of "what did I buy, where, for how
      # much" (design-log §22) — distinct from core's TransactionLog
      # (payment-dispatch bookkeeping) and OrderLedger (a settled-order
      # snapshot keyed for later lookup). Neither of those is shaped as a
      # journal, and neither belongs to a consumer wanting one durable
      # append-only trail across every completed purchase regardless of
      # which adapter or platform made it.
      #
      # Takes only what's already in hand at the dispatcher's settle point —
      # no re-fetch, no new schema. `checkout` is duck-typed against
      # Portage::Ucp::Checkout (currency, line_items — each a LineItem-shaped
      # object with #item.id, a bare integer #quantity, and #totals, an
      # array of Total-shaped objects with #type/#amount — and #order, an
      # OrderConfirmation-shaped object with #id), not against
      # Portage::Ucp::Order: Checkout#order is only ever an
      # order_confirmation stub (id/permalink_url/label per the UCP schema),
      # never the full Order with its own line_items. This gem carries no
      # runtime dependency on portage-ucp itself either way.
      class PurchaseJournal
        def initialize(store: FileStore.new, clock: -> { Time.now })
          @store = store
          @clock = clock
        end

        # One journal entry per line item — a checkout with several distinct
        # products is several purchases from the buyer's own point of view,
        # not one.
        #
        # @param shop [String, nil] merchant/store identity, same value
        #   Dispatcher already threads into TransactionLog.
        # @param source ["native_ucp", String] "native_ucp" for a
        #   direct/no-adapter dispatch, "adapter:<platform>" otherwise — see
        #   docs/plans/storage-abstraction-journal.md's open decision on the
        #   exact platform string.
        # @param checkout [#currency, #line_items, #order] the settled
        #   Checkout — Dispatcher's `result` at the complete_checkout settle
        #   point, same object #order_ledger snapshots `#order` from.
        # @param idempotency_key [String] joins this entry back to the
        #   TransactionLog/OrderLedger records from the same dispatch.
        # @return [Array<Hash>] the entries written, one per line item.
        def record_checkout(shop:, source:, checkout:, idempotency_key:)
          context = { shop: shop, source: source, order_id: checkout.order&.id,
                      idempotency_key: idempotency_key, recorded_at: @clock.call.utc.iso8601 }

          checkout.line_items.map do |line_item|
            entry = build_entry(line_item, checkout.currency, context)
            @store.append(entry)
            entry
          end
        end

        def each_record(&)
          @store.each_record(&)
        end

        def all
          enum_for(:each_record).to_a
        end

        private

        def build_entry(line_item, currency, context)
          {
            "shop" => context[:shop], "source" => context[:source], "product_id" => line_item.item.id,
            "quantity" => line_item.quantity, "amount" => line_total(line_item), "currency" => currency,
            "order_id" => context[:order_id], "idempotency_key" => context[:idempotency_key],
            "recorded_at" => context[:recorded_at]
          }
        end

        # Total#amount is a bare integer minor-unit amount — same convention
        # Dispatcher#settled_amount already follows for the checkout-level
        # total.
        def line_total(line_item)
          total = Array(line_item.totals).find { |t| t.type == "total" }
          total&.amount
        end
      end
    end
  end
end
