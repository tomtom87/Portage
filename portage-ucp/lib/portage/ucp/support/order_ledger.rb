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

        def find(order_id)
          @store.find(order_id)
        end
      end
    end
  end
end
