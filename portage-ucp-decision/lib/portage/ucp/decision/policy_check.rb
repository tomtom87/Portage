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
      # three decisions in this gem. `risk_signals:` is a placeholder for the
      # doc's unresearched addition (merchant age, TLS/manifest-signing
      # status, prior escalation rate) — accepted but not yet checked.
      module PolicyCheck
        Verdict = Data.define(:allowed, :reason, :decision)

        # @param risk_signals [Hash, nil] reserved; not yet checked.
        # @return [Verdict]
        def self.call(amount:, currency:, merchant:, token_ref:, policy: Portage::Ucp::Policy.load,
                      transaction_log: Portage::Ucp::Support::TransactionLog.new, risk_signals: nil) # rubocop:disable Lint/UnusedMethodArgument
          decision = Portage::Ucp::PolicyGuard.check!(amount: amount, currency: currency, merchant: merchant,
                                                      token_ref: token_ref, policy: policy,
                                                      transaction_log: transaction_log)
          Verdict.new(allowed: true, reason: nil, decision: decision)
        rescue Portage::Ucp::PolicyViolationError => e
          Verdict.new(allowed: false, reason: e.reason, decision: e.decision)
        end
      end
    end
  end
end
