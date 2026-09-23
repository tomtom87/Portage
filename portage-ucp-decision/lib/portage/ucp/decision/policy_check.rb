require "portage/ucp"

module Portage
  module Ucp
    module Decision
      # docs/plans/system-one-decision-layer.md § Responsibilities 4.
      #
      # Closest responsibility to done: `Portage::Ucp::PolicyGuard` already
      # covers per-transaction cap, rolling cap, velocity, and merchant
      # allowlist. This wraps it as a typed `Verdict` instead of a raised
      # exception, so a caller gets the same inspectable shape as the other
      # three decisions in this gem.
      #
      # `risk_signals:` implements the *mechanism* the doc's "simple policy
      # checks" responsibility calls for — a Hash of named booleans, any
      # truthy one denies — without inventing the specific signals
      # themselves (merchant age, TLS/manifest-signing status, prior
      # escalation rate). Nothing in this repo computes those today (no
      # merchant-trust/history helper exists under
      # `Portage::Ucp::Support`), so that stays the caller's job: compute
      # `{merchant_too_new: true}` however you like, hand it in here, and
      # it's enforced the same way a `PolicyGuard` cap is.
      module PolicyCheck
        Verdict = Data.define(:allowed, :reason, :decision)

        # @param risk_signals [Hash{Symbol => Boolean}, nil] any key whose
        #   value is truthy denies with `reason: :risk_signal_triggered`.
        # @return [Verdict]
        def self.call(amount:, currency:, merchant:, token_ref:, policy: Portage::Ucp::Policy.load,
                      transaction_log: Portage::Ucp::Support::TransactionLog.new, risk_signals: nil)
          triggered = triggered_risk_signals(risk_signals)
          return risk_signal_verdict(triggered) if triggered.any?

          decision = Portage::Ucp::PolicyGuard.check!(amount: amount, currency: currency, merchant: merchant,
                                                      token_ref: token_ref, policy: policy,
                                                      transaction_log: transaction_log)
          Verdict.new(allowed: true, reason: nil, decision: decision)
        rescue Portage::Ucp::PolicyViolationError => e
          Verdict.new(allowed: false, reason: e.reason, decision: e.decision)
        end

        def self.triggered_risk_signals(risk_signals)
          Hash(risk_signals).select { |_name, value| value }.keys
        end
        private_class_method :triggered_risk_signals

        def self.risk_signal_verdict(triggered)
          Verdict.new(allowed: false, reason: :risk_signal_triggered,
                      decision: { allowed: false, reason: :risk_signal_triggered, risk_signals: triggered })
        end
        private_class_method :risk_signal_verdict
      end
    end
  end
end
