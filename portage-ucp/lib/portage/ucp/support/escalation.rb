module Portage
  module Ucp
    module Support
      # The escalation rule (docs/plans/system-one-decision-layer.md
      # § Responsibilities 2), held in core for the same reason as
      # OfferRanking: portage-ucp-decision's EscalationPolicy wraps it, and
      # portage-cli calls it directly.
      #
      # The store's own `requires_escalation` wins over a mismatch the
      # caller found, so a checkout that is both reports the store's answer.
      module Escalation
        STATUS = "requires_escalation".freeze

        module_function

        # @param checkout_status [String, nil] a Checkout#status value.
        # @param warnings [Array<String>, nil] mismatches that should stop
        #   the purchase. Any one escalates. Pass none when mismatches are
        #   only to be reported.
        # @return [Symbol, nil] `:requires_escalation`, `:mismatch`, or nil
        #   to keep going.
        def reason(checkout_status:, warnings: [])
          return :requires_escalation if checkout_status == STATUS
          return :mismatch if Array(warnings).any?

          nil
        end
      end
    end
  end
end
