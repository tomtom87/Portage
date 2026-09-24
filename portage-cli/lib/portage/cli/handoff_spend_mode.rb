require_relative "config"
require_relative "setting"

module Portage
  module Cli
    # docs/plans/handoff-reconcile.md Phase 2 — how a shopper-paid,
    # reconciled handoff counts toward the buyer's own spend cap/velocity
    # limit (Portage::Ucp::PolicyGuard). Same Setting precedence as
    # CheckoutHandoff/Notifier: flag > PORTAGE_HANDOFF_SPEND_MODE > config.json's
    # "handoff_spend_mode". Unset, or set to anything not in MODES, is
    # `block`, the safer default (a shopper's own completed purchase is real
    # spend; hiding it from the cap would just let the next *agent* purchase
    # blow through it unnoticed).
    module HandoffSpendMode
      ENV_VAR = "PORTAGE_HANDOFF_SPEND_MODE".freeze
      CONFIG_KEY = "handoff_spend_mode".freeze
      MODES = %w[block warn precheck].freeze
      DEFAULT = "block".freeze

      module_function

      def resolve(override: nil, config: Config.load)
        mode = Setting.resolve(override: override, env: ENV_VAR, config: config, config_key: CONFIG_KEY)
        MODES.include?(mode) ? mode : DEFAULT
      end
    end
  end
end
