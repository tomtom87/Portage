require "json"
require "fileutils"
require "time"

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
        def complete(idempotency_key:, status:, amount: nil, currency: nil, policy_decision: nil,
                     confirmation_outcome: nil)
          raise ArgumentError, "status must be one of #{TERMINAL_STATUSES}" unless TERMINAL_STATUSES.include?(status)

          with_lock(File::LOCK_EX) do |data, file|
            record = data[idempotency_key]
            raise KeyError, "no transaction reserved for idempotency_key #{idempotency_key.inspect}" unless record

            record["status"] = status
            record["amount"] = amount unless amount.nil?
            record["currency"] = currency unless currency.nil?
            record["policy_decision"] = policy_decision unless policy_decision.nil?
            record["confirmation_outcome"] = confirmation_outcome unless confirmation_outcome.nil?
            record["completed_at"] = @clock.call.utc.iso8601
            persist(data, file)
            record
          end
        end

        # Called mid-flight, between a passing PolicyGuard.check! and the
        # adapter dispatch it gates — so a passing decision is on record even
        # if the process dies during the adapter's own gateway round-trip,
        # same reasoning as `reserve` landing before dispatch. A *blocking*
        # decision goes through `#complete(status: "failed", policy_decision:)`
        # instead, since a block never reaches dispatch at all.
        def record_decision(idempotency_key:, policy_decision:)
          with_lock(File::LOCK_EX) do |data, file|
            record = data[idempotency_key]
            raise KeyError, "no transaction reserved for idempotency_key #{idempotency_key.inspect}" unless record

            record["policy_decision"] = policy_decision
            persist(data, file)
            record
          end
        end

        # Called mid-flight, between a passing Confirmer#confirm! and the
        # adapter dispatch it gates — same "record before the risky part"
        # reasoning as `record_decision`. A *denying* outcome goes through
        # `#complete(status: "failed", confirmation_outcome:)` instead, since
        # a deny never reaches dispatch at all.
        def record_confirmation(idempotency_key:, confirmation_outcome:)
          with_lock(File::LOCK_EX) do |data, file|
            record = data[idempotency_key]
            raise KeyError, "no transaction reserved for idempotency_key #{idempotency_key.inspect}" unless record

            record["confirmation_outcome"] = confirmation_outcome
            persist(data, file)
            record
          end
        end

        def find(idempotency_key)
          with_lock(File::LOCK_SH) { |data, _file| data[idempotency_key] }
        end

        # Rolling-window records for PolicyGuard's spend cap / velocity
        # checks — "complete" only (a "failed"/"pending" attempt never moved
        # money, so it shouldn't count against a spend or velocity limit).
        # Scoped to `shop` since caps/velocity are per-merchant in the policy
        # file's mental model (a global cross-shop cap isn't a v1 goal).
        def completed_since(since, shop:)
          with_lock(File::LOCK_SH) do |data, _file|
            data.values.select do |record|
              record["status"] == "complete" && record["shop"] == shop && record["completed_at"] &&
                Time.parse(record["completed_at"]) >= since
            end
          end
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
