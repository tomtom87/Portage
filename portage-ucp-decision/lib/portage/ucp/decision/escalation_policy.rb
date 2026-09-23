require "portage/ucp"

module Portage
  module Ucp
    module Decision
      # docs/plans/system-one-decision-layer.md § Responsibilities 2.
      #
      # A typed wrapper around `Portage::Ucp::Support::Escalation`, the way
      # PolicyCheck wraps `PolicyGuard`. The rule lives in core: the literal
      # `requires_escalation` status wins, then a mismatch the caller found.
      # That covers the doc's "ambiguous signal" case, a merchant surfacing
      # a mismatch that isn't literally `requires_escalation` but should
      # still stop here. `signals: {warnings:}` takes the same
      # `warnings: [String]` array `portage buy` puts on its report.
      module EscalationPolicy
        Verdict = Data.define(:escalate, :reason)

        ESCALATING_STATUSES = [Portage::Ucp::Support::Escalation::STATUS].freeze

        # @param checkout_status [String] a Checkout#status value.
        # @param signals [Hash] `warnings:` an Array of human-readable
        #   mismatch strings (any element escalates), `mismatch:` an
        #   explicit boolean for a caller that's already decided but has no
        #   string to show. Either alone is enough; neither is required.
        def self.call(checkout_status:, signals: {})
          reason = Portage::Ucp::Support::Escalation.reason(checkout_status: checkout_status,
                                                            warnings: signals[:warnings])
          reason ||= :mismatch if signals[:mismatch] == true

          Verdict.new(escalate: !reason.nil?, reason: reason)
        end
      end
    end
  end
end
