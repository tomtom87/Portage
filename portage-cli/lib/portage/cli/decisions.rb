require "portage/ucp"

module Portage
  module Cli
    # The one place portage-cli touches `portage-ucp-decision`
    # (docs/plans/system-one-decision-layer.md), which is an optional
    # dependency. It isn't in the gemspec, so `gem install portage-cli`
    # stays light. When the gem is installed, `buy` and `find` make their
    # judgment calls through it. When it isn't, the built-in fallbacks below
    # give the same answers.
    #
    # Every method returns a plain Hash, never one of the gem's Verdict
    # types, so callers don't care which path answered. The fallbacks copy
    # the gem's rules on purpose, and decisions_spec runs both paths
    # against the same cases so the two can't drift apart.
    #
    # Only the confidence gate has no fallback. It needs a model backend,
    # and those live in the gem (see ConfidenceCheck).
    module Decisions
      ESCALATING_STATUSES = %w[requires_escalation].freeze

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

      # Buyable first, then cheapest, then unpriced, stable otherwise.
      # @param offers [Array<Hash>] with `:checkout` (buyable) and `:amount`.
      def self.rank(offers)
        return gem_rank(offers) if available?

        offers.sort_by.with_index do |offer, index|
          [offer[:checkout] ? 0 : 1, offer[:amount] ? 0 : 1, offer[:amount] || 0, index]
        end
      end

      # @param warnings [Array<String>] mismatches that should escalate —
      #   pass none when mismatches are only to be reported.
      # @return [Hash] `escalate:`, `reason:`.
      def self.escalation(checkout_status:, warnings: [])
        if available?
          return Portage::Ucp::Decision::EscalationPolicy
                 .call(checkout_status: checkout_status, signals: { warnings: warnings }).to_h
        end

        return { escalate: true, reason: :requires_escalation } if ESCALATING_STATUSES.include?(checkout_status)
        return { escalate: true, reason: :mismatch } if Array(warnings).any?

        { escalate: false, reason: nil }
      end

      # The buyer's spend policy. PolicyGuard lives in portage-ucp core, so
      # this check runs with or without the decision gem.
      #
      # PolicyGuard skips both spend caps when `amount` is nil, which suits
      # its own caller (an adapter that can't price a checkout up front).
      # Here it would let a checkout with no `total` line past a configured
      # cap while reporting `allowed: true`, so a missing total is denied as
      # `:total_unknown` whenever a cap exists.
      # @return [Hash] `allowed:`, `reason:`.
      def self.policy(amount:, currency:, merchant:, token_ref:)
        if amount.nil?
          policy = Portage::Ucp::Policy.load
          return { allowed: false, reason: :total_unknown } if policy.per_transaction_cap || policy.rolling_cap
        end

        if available?
          verdict = Portage::Ucp::Decision::PolicyCheck.call(amount: amount, currency: currency,
                                                             merchant: merchant, token_ref: token_ref)
          return { allowed: verdict.allowed, reason: verdict.reason }
        end

        Portage::Ucp::PolicyGuard.check!(amount: amount, currency: currency, merchant: merchant,
                                         token_ref: token_ref)
        { allowed: true, reason: nil }
      rescue Portage::Ucp::PolicyViolationError => e
        { allowed: false, reason: e.reason }
      end

      def self.gem_rank(offers)
        candidates = offers.map do |offer|
          Portage::Ucp::Decision::OfferRanking::Candidate.new(offer: offer, buyable: offer[:checkout],
                                                              amount: offer[:amount])
        end
        Portage::Ucp::Decision::OfferRanking.call(candidates).map(&:offer)
      end
      private_class_method :gem_rank
    end
  end
end
