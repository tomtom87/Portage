require "time"
require_relative "transaction_log/store"
require_relative "transaction_log/file_store"

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
      # Storage is pluggable via `store:` (see `Store`/`FileStore`,
      # design-log §33) — `path:` stays as a shorthand for the file-backed
      # default, so every existing caller keeps working unchanged.
      class TransactionLog
        PATH = FileStore::PATH
        TERMINAL_STATUSES = %w[complete failed].freeze

        def initialize(store: nil, path: PATH, clock: -> { Time.now })
          @store = store || FileStore.new(path: path)
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

          @store.reserve(record)
        end

        # Called after dispatch settles, success or failure. Raises if no
        # `reserve` was ever recorded for this key — completing a
        # transaction that was never reserved means a call site skipped the
        # reserve step, which is the exact bug Phase 0 exists to prevent.
        def complete(idempotency_key:, status:, amount: nil, currency: nil, policy_decision: nil,
                     confirmation_outcome: nil)
          raise ArgumentError, "status must be one of #{TERMINAL_STATUSES}" unless TERMINAL_STATUSES.include?(status)

          updates = { "status" => status, "completed_at" => @clock.call.utc.iso8601 }
          updates["amount"] = amount unless amount.nil?
          updates["currency"] = currency unless currency.nil?
          updates["policy_decision"] = policy_decision unless policy_decision.nil?
          updates["confirmation_outcome"] = confirmation_outcome unless confirmation_outcome.nil?

          record = @store.complete(idempotency_key, updates)
          raise KeyError, "no transaction reserved for idempotency_key #{idempotency_key.inspect}" unless record

          record
        end

        # Called mid-flight, between a passing PolicyGuard.check! and the
        # adapter dispatch it gates — so a passing decision is on record even
        # if the process dies during the adapter's own gateway round-trip,
        # same reasoning as `reserve` landing before dispatch. A *blocking*
        # decision goes through `#complete(status: "failed", policy_decision:)`
        # instead, since a block never reaches dispatch at all.
        def record_decision(idempotency_key:, policy_decision:)
          record = @store.record_decision(idempotency_key, policy_decision)
          raise KeyError, "no transaction reserved for idempotency_key #{idempotency_key.inspect}" unless record

          record
        end

        # Called mid-flight, between a passing Confirmer#confirm! and the
        # adapter dispatch it gates — same "record before the risky part"
        # reasoning as `record_decision`. A *denying* outcome goes through
        # `#complete(status: "failed", confirmation_outcome:)` instead, since
        # a deny never reaches dispatch at all.
        def record_confirmation(idempotency_key:, confirmation_outcome:)
          record = @store.record_confirmation(idempotency_key, confirmation_outcome)
          raise KeyError, "no transaction reserved for idempotency_key #{idempotency_key.inspect}" unless record

          record
        end

        def find(idempotency_key)
          @store.find(idempotency_key)
        end

        # Rolling-window records for PolicyGuard's spend cap / velocity
        # checks — "complete" only (a "failed"/"pending" attempt never moved
        # money, so it shouldn't count against a spend or velocity limit).
        # Scoped to `shop` since caps/velocity are per-merchant in the policy
        # file's mental model (a global cross-shop cap isn't a v1 goal).
        def completed_since(since, shop:)
          @store.completed_since(since, shop: shop)
        end
      end
    end
  end
end
