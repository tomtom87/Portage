require "json"
require "fileutils"
require "time"

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
      class OrderLedger
        PATH = File.join(Dir.home, ".portage", "orders.json").freeze

        def initialize(path: PATH, clock: -> { Time.now })
          @path = path
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

          with_lock(File::LOCK_EX) do |data, file|
            data[order.id] = record
            persist(data, file)
          end

          record
        end

        def find(order_id)
          with_lock(File::LOCK_SH) { |data, _file| data[order_id] }
        end

        private

        def with_lock(lock_mode)
          FileUtils.mkdir_p(File.dirname(@path))
          File.open(@path, File::RDWR | File::CREAT, 0o600) do |file|
            file.flock(lock_mode)
            yield(read(file), file)
          end
        end

        def read(file)
          file.rewind
          raw = file.read
          return {} if raw.empty?

          parsed = JSON.parse(raw)
          parsed.is_a?(Hash) ? parsed : {}
        rescue JSON::ParserError
          {}
        end

        # No `rescue StandardError; nil` — see class comment. A failed write
        # here must raise, not vanish.
        def persist(data, file)
          file.rewind
          file.truncate(0)
          file.write(JSON.pretty_generate(data))
          file.flush
          File.chmod(0o600, @path)
        end
      end
    end
  end
end
