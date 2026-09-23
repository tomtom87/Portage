module Portage
  module Ucp
    module Decision
      # docs/plans/system-one-decision-layer.md § Responsibilities 2.
      #
      # Today `requires_escalation` branching is a rule the agent is told to
      # follow (skills/shop-via-ucp.md guardrail 2), not a decision a caller
      # can invoke and test. This makes that explicit call, still only for
      # the literal status — deciding escalation from ambiguous signals that
      # *aren't* literally `requires_escalation` is the doc's open question,
      # unimplemented here (signals: is accepted for that future case, but
      # every key is currently ignored).
      module EscalationPolicy
        Verdict = Data.define(:escalate, :reason)

        ESCALATING_STATUSES = %w[requires_escalation].freeze

        # @param checkout_status [String] a Checkout#status value.
        # @param signals [Hash] reserved for the ambiguous-signal case (doc's
        #   open question) — not yet consulted.
        def self.call(checkout_status:, signals: {}) # rubocop:disable Lint/UnusedMethodArgument
          if ESCALATING_STATUSES.include?(checkout_status)
            Verdict.new(escalate: true, reason: :requires_escalation)
          else
            Verdict.new(escalate: false, reason: nil)
          end
        end
      end
    end
  end
end
