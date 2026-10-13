require "time"
require_relative "order_ledger/store"
require_relative "order_ledger/file_store"

module Portage
  module Ucp
    module Support
      # Local, durable snapshot of settled orders — written once, immutable
      # by construction (see docs/plans/order-ledger.md, Phase 1). Separate
      # file from `transactions.json`: different retention, different read
      # pattern (PolicyGuard scans transactions on every spend-cap check;
      # order snapshots have no such hot path).
      #
      # Same raising-write posture as TransactionLog, for the same reason —
      # a silently lost order snapshot is an unnoticed hole in the evidence
      # trail. Do not add a `rescue StandardError; nil` here.
      #
      # Storage is pluggable via `store:` (see `Store`/`FileStore`,
      # design-log §33) — `path:` stays as a shorthand for the file-backed
      # default, so every existing caller keeps working unchanged.
      class OrderLedger
        PATH = FileStore::PATH

        def initialize(store: nil, path: PATH, clock: -> { Time.now })
          @store = store || FileStore.new(path: path)
          @clock = clock
        end

        # Snapshots `order.to_wire_h` keyed by order id, plus the
        # `idempotency_key` of the dispatch that produced it so the snapshot
        # can be joined back to its TransactionLog record.
        def record(idempotency_key:, order:)
          record = {
            "idempotency_key" => idempotency_key, "order" => order.to_wire_h,
            "recorded_at" => @clock.call.utc.iso8601
          }

          @store.record(order.id, record)
        end

        # Phase 3: replaces the stored snapshot's `adjustments` with
        # `order.adjustments` — the upstream list is authoritative for
        # adjustment state (a `pending` return settles on the merchant's
        # clock), so a merge would only keep stale statuses. Every other
        # purchase fact stays exactly as first recorded; `order`'s own
        # line items/totals are never read.
        #
        # No-op (returns nil) when there's no purchase snapshot for the
        # order: Phase 2's "report the gap, don't backfill" rule — a
        # post-purchase payload isn't evidence of what was originally paid.
        #
        # ponytail: find-then-record isn't one lock; a write landing in
        # between is lost. Add a Store#update if two writers ever share an
        # order id concurrently.
        def record_adjustments(order)
          existing = find(order.id)
          return nil unless existing

          # Same omit-when-empty shape as Order#to_wire_h.
          adjustments = order.adjustments.map(&:to_wire_h)
          snapshot = existing["order"].except("adjustments")
          snapshot = existing["order"].merge("adjustments" => adjustments) unless adjustments.empty?
          @store.record(order.id, existing.merge("order" => snapshot))
        end

        # Explicit reconcile for adjustments with no originating dispatch
        # (disputes) or that settle later (returns) — re-fetches via the
        # caller's `adapter` and merges adjustments only, per
        # #record_adjustments. No polling (plan Phase 3): call it when you
        # want current state.
        def refresh(order_id, adapter:)
          order = adapter.get_order(order_id: order_id)
          record_adjustments(order) if order
        end

        # Adjustments still `pending` — money owed but not yet received —
        # each paired with its order id.
        def unresolved
          all.flat_map do |record|
            order = record["order"]
            Array(order["adjustments"]).select { |adjustment| adjustment["status"] == "pending" }
                                       .map { |adjustment| { "order_id" => order["id"], "adjustment" => adjustment } }
          end
        end

        def find(order_id)
          @store.find(order_id)
        end

        def each_record(&)
          @store.each_record(&)
        end

        def all
          enum_for(:each_record).to_a
        end
      end
    end
  end
end
