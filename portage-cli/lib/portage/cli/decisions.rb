require "portage/ucp"

module Portage
  module Cli
    # portage-cli's judgment calls (docs/plans/system-one-decision-layer.md).
    # The rules live in portage-ucp core: Support::OfferRanking,
    # Support::Escalation and PolicyGuard. portage-ucp-decision's
    # OfferRanking, EscalationPolicy and PolicyCheck are typed wrappers
    # around those same modules, so `buy` and `find` answer the same way
    # whether or not that gem is installed.
    #
    # Every method returns a plain Hash whose `reason` is a String or nil,
    # so a caller sees the same values in-process as in `--json`.
    #
    # Only the confidence gate needs the optional gem, because the model
    # backends live there (see ConfidenceCheck and .available?).
    module Decisions
      # Loaded the way Resolver.build_adapter's callers treat an optional
      # adapter gem: `require`, then rescue LoadError. It isn't in the
      # gemspec, so `gem install portage-cli` stays light.
      # @return [Boolean] whether portage-ucp-decision could be loaded.
      #   Memoized: `require` runs once per process.
      def self.available?
        return @available unless @available.nil?

        @available = begin
          require "portage/ucp/decision"
          true
        rescue LoadError
          false
        end
      end

      # @param offers [Array<Hash>] with `:checkout` (buyable) and `:amount`.
      def self.rank(offers)
        Portage::Ucp::Support::OfferRanking.rank(offers) { |offer| [offer[:checkout], offer[:amount]] }
      end

      # @param warnings [Array<String>] mismatches that should escalate —
      #   pass none when mismatches are only to be reported.
      # @return [Hash] `escalate:`, `reason:`.
      def self.escalation(checkout_status:, warnings: [])
        reason = Portage::Ucp::Support::Escalation.reason(checkout_status: checkout_status, warnings: warnings)
        { escalate: !reason.nil?, reason: reason&.to_s }
      end

      # The buyer's spend policy, checked by PolicyGuard.
      #
      # PolicyGuard skips both spend caps when `amount` is nil, which suits
      # its own caller (an adapter that can't price a checkout up front).
      # Here it would let a checkout with no `total` line past a configured
      # cap while reporting `allowed: true`, so a missing total is denied as
      # `total_unknown` whenever a cap exists.
      # @param transaction_log [Portage::Ucp::Support::TransactionLog] what
      #   the rolling cap and velocity limit count.
      # @return [Hash] `allowed:`, `reason:`.
      def self.policy(amount:, currency:, merchant:, token_ref:,
                      transaction_log: Portage::Ucp::Support::TransactionLog.new)
        policy = Portage::Ucp::Policy.load
        if amount.nil? && (policy.per_transaction_cap || policy.rolling_cap)
          return { allowed: false, reason: "total_unknown" }
        end

        Portage::Ucp::PolicyGuard.check!(amount: amount, currency: currency, merchant: merchant,
                                         token_ref: token_ref, policy: policy, transaction_log: transaction_log)
        { allowed: true, reason: nil }
      rescue Portage::Ucp::PolicyViolationError => e
        { allowed: false, reason: e.reason.to_s }
      end
    end
  end
end
