module Portage
  module Ucp
    module Decision
      # docs/plans/system-one-decision-layer.md § Responsibilities 2.
      #
      # Today `requires_escalation` branching is a rule the agent is told to
      # follow (skills/shop-via-ucp.md guardrail 2), not a decision a caller
      # can invoke and test. This makes that explicit call for the literal
      # status, plus the doc's "ambiguous signal" case: a merchant surfacing
      # a mismatch that isn't literally `requires_escalation` but should
      # still stop here. `signals:` matches the vocabulary the not-yet-merged
      # checkout-mismatch fix (commit 82631bf, branch
      # feature/escalation-buyer-context-hardening) uses on its `Buy` report
      # — a plain `warnings: [String]` array, no dedicated wire-level
      # "mismatch" type exists anywhere in this repo — so this stays
      # forward-compatible with that shape without depending on the branch.
      module EscalationPolicy
        Verdict = Data.define(:escalate, :reason)

        ESCALATING_STATUSES = %w[requires_escalation].freeze

        # @param checkout_status [String] a Checkout#status value.
        # @param signals [Hash] `warnings:` an Array of human-readable
        #   mismatch strings (any element escalates), `mismatch:` an
        #   explicit boolean for a caller that's already decided but has no
        #   string to show. Either alone is enough; neither is required.
        def self.call(checkout_status:, signals: {})
          return Verdict.new(escalate: true, reason: :requires_escalation) if escalating_status?(checkout_status)
          return Verdict.new(escalate: true, reason: :mismatch) if mismatch?(signals)

          Verdict.new(escalate: false, reason: nil)
        end

        def self.escalating_status?(checkout_status) = ESCALATING_STATUSES.include?(checkout_status)
        private_class_method :escalating_status?

        def self.mismatch?(signals) = signals[:mismatch] == true || Array(signals[:warnings]).any?
        private_class_method :mismatch?
      end
    end
  end
end
