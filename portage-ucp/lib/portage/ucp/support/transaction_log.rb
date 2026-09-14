require "json"
require "fileutils"

module Portage
  module Ucp
    module Support
      # Local, durable record of payment-completing dispatches — reserved
      # `pending` *before* the adapter is asked to complete a checkout,
      # settled to `complete`/`failed` after. A crash mid-charge leaves the
      # `pending` record behind as evidence instead of silence (see
      # docs/plans/agentic-payments.md, Phase 0).
      #
      # Deliberately does NOT follow the `History`/`ProbeCache`/
      # `search_backends` convention of swallowing write failures
      # (`rescue StandardError; nil`) — a lost write here means dedup/
      # spend-cap state silently drifts and a later run can misjudge spend
      # or re-charge, whereas a lost write to those is just a forgotten
      # local note. Write failures on this file raise.
      #
      # `chmod 0600` on every write: none of the existing `~/.portage/*`
      # files do this today, but this one carries payment_token_ref/amount
      # data, so it gets a stricter, explicit convention of its own.
      class TransactionLog
        PATH = File.join(Dir.home, ".portage", "transactions.json").freeze
        TERMINAL_STATUSES = %w[complete failed].freeze

        def initialize(path: PATH, clock: -> { Time.now })
          @path = path
          @clock = clock
        end

        # Called before dispatch. `amount`/`currency` are frequently unknown
        # at this point (the caller hasn't fetched or received the priced
        # checkout yet) — left nil rather than delaying the reserve on an
        # extra lookup; `#complete` fills them in from the settled result.
        def reserve(idempotency_key:, checkout_id:, payment_token_ref:, shop: nil, amount: nil, currency: nil)
          record = {
            "idempotency_key" => idempotency_key, "shop" => shop, "checkout_id" => checkout_id,
            "status" => "pending", "policy_decision" => nil, "confirmation_outcome" => nil,
            "payment_token_ref" => payment_token_ref, "amount" => amount, "currency" => currency,
            "created_at" => @clock.call.utc.iso8601, "completed_at" => nil
          }

          with_lock(File::LOCK_EX) do |data, file|
            data[idempotency_key] = record
            persist(data, file)
          end

          record
        end

        # Called after dispatch settles, success or failure. Raises if no
        # `reserve` was ever recorded for this key — completing a
        # transaction that was never reserved means a call site skipped the
        # reserve step, which is the exact bug Phase 0 exists to prevent.
        def complete(idempotency_key:, status:, amount: nil, currency: nil)
          raise ArgumentError, "status must be one of #{TERMINAL_STATUSES}" unless TERMINAL_STATUSES.include?(status)

          with_lock(File::LOCK_EX) do |data, file|
            record = data[idempotency_key]
            raise KeyError, "no transaction reserved for idempotency_key #{idempotency_key.inspect}" unless record

            record["status"] = status
            record["amount"] = amount unless amount.nil?
            record["currency"] = currency unless currency.nil?
            record["completed_at"] = @clock.call.utc.iso8601
            persist(data, file)
            record
          end
        end

        def find(idempotency_key)
          with_lock(File::LOCK_SH) { |data, _file| data[idempotency_key] }
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
