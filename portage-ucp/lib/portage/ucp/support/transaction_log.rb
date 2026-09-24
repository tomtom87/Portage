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

        # Handoff-reconcile's extension point (docs/plans/handoff-reconcile.md,
        # "Core changes stay minimal, additive and in one place"): a fixed
        # allowlist of optional attributes `reserve`/`complete` accept beyond
        # their named keywords, rather than a `reserve_handoff`/
        # `settle_handoff` pair — a handoff is a transaction record with extra
        # attributes, not a parallel path. Unknown keys raise `ArgumentError`
        # so a typo'd attribute fails loudly instead of being silently
        # dropped. A record with none of these set reads exactly as it did
        # before this allowlist existed (see each accessor's own comment
        # below for what absence means).
        OPTIONAL_ATTRIBUTES = %w[settled_by handoff_reason store_url expires_at resolution
                                 counts_toward_caps].freeze

        def initialize(store: nil, path: PATH, clock: -> { Time.now })
          @store = store || FileStore.new(path: path)
          @clock = clock
        end

        # Called before dispatch. `amount`/`currency` are frequently unknown
        # at this point (the caller hasn't fetched or received the priced
        # checkout yet) — left nil rather than delaying the reserve on an
        # extra lookup; `#complete` fills them in from the settled result.
        #
        # @param settled_by [String, nil] absent/nil means the
        #   agent/dispatcher reserved this record, as always. `"shopper"`
        #   marks a pending hand-off — a checkout `portage buy` couldn't
        #   finish itself, handed to the shopper's own browser (see
        #   Portage::Cli::HandoffReconciler). Reconcile only ever touches
        #   `settled_by: "shopper"` records, never Dispatcher's own
        #   crash-evidence `pending` rows.
        # rubocop:disable Metrics/ParameterLists -- all keywords, plus the OPTIONAL_ATTRIBUTES allowlist splat
        def reserve(idempotency_key:, checkout_id:, payment_token_ref:, shop: nil, amount: nil, currency: nil,
                    **optional_attributes)
          # rubocop:enable Metrics/ParameterLists
          validate_optional_attributes!(optional_attributes)

          record = {
            "idempotency_key" => idempotency_key, "shop" => shop, "checkout_id" => checkout_id,
            "status" => "pending", "policy_decision" => nil, "confirmation_outcome" => nil,
            "payment_token_ref" => payment_token_ref, "amount" => amount, "currency" => currency,
            "created_at" => @clock.call.utc.iso8601, "completed_at" => nil
          }.merge(stringify_keys(optional_attributes))

          @store.reserve(record)
        end

        # Called after dispatch settles, success or failure. Raises if no
        # `reserve` was ever recorded for this key — completing a
        # transaction that was never reserved means a call site skipped the
        # reserve step, which is the exact bug Phase 0 exists to prevent.
        #
        # @param resolution [String, nil] handoff-reconcile only — how a
        #   `failed` settle was decided when the store never reported a
        #   terminal status itself: `"expired"` (the checkout's own
        #   `expires_at` passed with no answer) or `"unknown"` (the checkout
        #   vanished/errored and then expired). Absent for every other
        #   settle, including a store-reported `canceled`.
        # @param counts_toward_caps [Boolean, nil] absent means true, same
        #   as always — PolicyGuard's rolling cap/velocity counted every
        #   `complete` record before this existed. `false` marks a
        #   `handoff_spend_mode: warn` settle so `#completed_since` (below)
        #   excludes it.
        # rubocop:disable Metrics/ParameterLists -- all keywords, plus the OPTIONAL_ATTRIBUTES allowlist splat
        def complete(idempotency_key:, status:, amount: nil, currency: nil, policy_decision: nil,
                     confirmation_outcome: nil, **optional_attributes)
          # rubocop:enable Metrics/ParameterLists
          raise ArgumentError, "status must be one of #{TERMINAL_STATUSES}" unless TERMINAL_STATUSES.include?(status)

          validate_optional_attributes!(optional_attributes)

          updates = { "status" => status, "completed_at" => @clock.call.utc.iso8601 }
          updates["amount"] = amount unless amount.nil?
          updates["currency"] = currency unless currency.nil?
          updates["policy_decision"] = policy_decision unless policy_decision.nil?
          updates["confirmation_outcome"] = confirmation_outcome unless confirmation_outcome.nil?
          updates.merge!(stringify_keys(optional_attributes))

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
        #
        # `counts_toward_caps: false` records are filtered out here, in the
        # wrapper, not in each `Store` (docs/plans/handoff-reconcile.md
        # Phase 2, "core field, filtered once") — so `FileStore` and any
        # custom Store, and every caller through them (CLI, MCP server,
        # Dispatcher), see the same numbers without re-implementing the
        # rule. A record with no `counts_toward_caps` field still counts,
        # same as before this field existed.
        def completed_since(since, shop:)
          @store.completed_since(since, shop: shop).reject { |record| record["counts_toward_caps"] == false }
        end

        def each_record(&)
          @store.each_record(&)
        end

        def all
          enum_for(:each_record).to_a
        end

        private

        def validate_optional_attributes!(optional_attributes)
          unknown = optional_attributes.keys.map(&:to_s) - OPTIONAL_ATTRIBUTES
          return if unknown.empty?

          raise ArgumentError, "unknown optional attribute(s): #{unknown.join(', ')} " \
                               "(allowed: #{OPTIONAL_ATTRIBUTES.join(', ')})"
        end

        def stringify_keys(hash) = hash.transform_keys(&:to_s)
      end
    end
  end
end
