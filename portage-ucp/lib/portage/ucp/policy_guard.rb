module Portage
  module Ucp
    # In-core policy gate (docs/plans/agentic-payments.md Phase 2) called
    # from Dispatcher before any payment-completing dispatch, alongside the
    # existing PaymentTokenGuard call. Guards agent mistakes (a runaway loop,
    # a merchant typo, a misused token), not a compromised agent — anyone
    # running as the local user can edit the policy file; the real backstop
    # against that is an issuer-side limit, documented in the README, not
    # this module.
    #
    # Public API is kept deliberately small and stable since `portage-ucp`
    # is a published gem — the Policy file format behind it is free to
    # change across releases.
    module PolicyGuard
      # @param amount [Integer, nil] minor-unit amount, from the checkout
      #   Dispatcher fetches before dispatch. nil skips the two cap checks
      #   (an adapter that can't price a checkout up front has nothing for
      #   a spend cap to compare against) but never skips velocity/allowlist/
      #   scope — those don't need an amount to matter.
      # @param currency [String, nil]
      # @param merchant [String, nil] the shop identity Dispatcher was built
      #   with (`shop:`) — one Dispatcher instance completes charges for one
      #   store, so this isn't a per-call argument the caller picks.
      # @param token_ref [String, nil] from Support::TokenRef.for.
      # @raise [Portage::Ucp::PolicyViolationError] on the first failing
      #   check, in the plan's stated order: spend cap, velocity, merchant
      #   allowlist, per-token scope.
      # @return [Hash] the passing decision, suitable for
      #   TransactionLog#record_decision / #complete's `policy_decision:`.
      def self.check!(amount:, currency:, merchant:, token_ref:, policy: Portage::Ucp::Policy.load,
                      transaction_log: Portage::Ucp::Support::TransactionLog.new)
        check_spend_cap(amount, currency, merchant, policy, transaction_log)
        check_velocity(merchant, policy, transaction_log)
        check_merchant_allowlist(merchant, policy)
        check_token_scope(amount, currency, merchant, token_ref, policy)

        { allowed: true }
      end

      def self.check_spend_cap(amount, currency, merchant, policy, transaction_log)
        return if amount.nil?

        check_per_transaction_cap(amount, currency, policy.per_transaction_cap)
        check_rolling_cap(amount, merchant, policy.rolling_cap, transaction_log)
      end
      private_class_method :check_spend_cap

      def self.check_per_transaction_cap(amount, currency, cap)
        return unless cap

        require_matching_currency!(currency, cap["currency"])
        return unless amount > cap["amount"]

        deny!(:per_transaction_cap_exceeded,
              "amount #{amount} #{currency} exceeds per-transaction cap #{cap['amount']} #{cap['currency']}")
      end
      private_class_method :check_per_transaction_cap

      def self.check_rolling_cap(amount, merchant, rolling, transaction_log)
        return unless rolling

        window_start = Time.now - rolling["window_seconds"]
        prior_spend = transaction_log.completed_since(window_start, shop: merchant).sum do |record|
          require_matching_currency!(record["currency"], rolling["currency"])
          record["amount"].to_i
        end
        total = prior_spend + amount
        return if total <= rolling["amount"]

        deny!(:rolling_spend_cap_exceeded,
              "rolling spend #{total} #{rolling['currency']} over #{rolling['window_seconds']}s exceeds cap " \
              "#{rolling['amount']} #{rolling['currency']}")
      end
      private_class_method :check_rolling_cap

      def self.check_velocity(merchant, policy, transaction_log)
        limit = policy.velocity
        return unless limit

        window_start = Time.now - limit["window_seconds"]
        count = transaction_log.completed_since(window_start, shop: merchant).length
        return if count < limit["count"]

        deny!(:velocity_exceeded,
              "#{count} completed transactions in the last #{limit['window_seconds']}s meets or exceeds velocity " \
              "limit #{limit['count']}")
      end
      private_class_method :check_velocity

      def self.check_merchant_allowlist(merchant, policy)
        allowlist = policy.merchant_allowlist
        return if allowlist.empty?
        return if merchant && host_allowed?(merchant, allowlist)

        deny!(:merchant_not_allowlisted, "merchant #{merchant.inspect} is not in the configured allowlist")
      end
      private_class_method :check_merchant_allowlist

      def self.check_token_scope(amount, currency, merchant, token_ref, policy)
        scope = token_ref && policy.token_scope(token_ref)
        return unless scope

        check_token_scope_merchant(merchant, scope)
        check_token_scope_amount(amount, currency, scope)
      end
      private_class_method :check_token_scope

      def self.check_token_scope_merchant(merchant, scope)
        merchants = Array(scope["merchants"])
        return if merchants.empty? || (merchant && host_allowed?(merchant, merchants))

        deny!(:token_scope_merchant, "token is scoped to #{merchants}, not #{merchant.inspect}")
      end
      private_class_method :check_token_scope_merchant

      def self.check_token_scope_amount(amount, currency, scope)
        max_amount = scope["max_amount"]
        return unless max_amount && amount

        require_matching_currency!(currency, scope["currency"])
        return unless amount > max_amount

        deny!(:token_scope_amount, "amount #{amount} exceeds token scope max #{max_amount}")
      end
      private_class_method :check_token_scope_amount

      # No implicit conversion — a currency mismatch is rejected outright
      # rather than guessed at, per the plan's spend-cap check.
      def self.require_matching_currency!(actual, expected)
        return if actual.nil? || expected.nil? || actual == expected

        deny!(:currency_mismatch, "currency #{actual} does not match policy currency #{expected} — " \
                                  "no implicit conversion")
      end
      private_class_method :require_matching_currency!

      def self.deny!(reason, message)
        raise Portage::Ucp::PolicyViolationError.new(message, reason: reason,
                                                              decision: { allowed: false, reason: reason })
      end
      private_class_method :deny!

      # Exact host match, or subdomain of a registrable domain in the
      # allowlist — "shop.example.com" matches an "example.com" entry, but
      # "evil-example.com" never matches "example.com" (no substring match).
      def self.host_allowed?(host, allowlist)
        allowlist.any? { |entry| host == entry || host.end_with?(".#{entry}") }
      end
      private_class_method :host_allowed?
    end
  end
end
