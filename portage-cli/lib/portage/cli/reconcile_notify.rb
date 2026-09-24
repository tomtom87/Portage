require_relative "config"
require_relative "setting"

module Portage
  module Cli
    # docs/plans/handoff-reconcile.md Phase 3 — which channels fire when a
    # handoff settles, from `portage buy --wait` or `portage orders
    # reconcile` (see ReconcileNotifier). A comma list, same Setting
    # precedence as every other standing preference here: an explicit
    # `override:` beats PORTAGE_RECONCILE_NOTIFY, which beats config.json's
    # "reconcile_notify". Unset is `webhook` only.
    #
    # "journal" is accepted but drives nothing here: the Phase 1 order
    # snapshot journal write already happens unconditionally in
    # HandoffReconciler#record_journal whenever a completed checkout carries
    # an order. Naming it in `reconcile_notify` documents that as always-on
    # rather than gating a second write path.
    module ReconcileNotify
      ENV_VAR = "PORTAGE_RECONCILE_NOTIFY".freeze
      CONFIG_KEY = "reconcile_notify".freeze
      CHANNELS = %w[webhook journal macos terminal].freeze
      DEFAULT = %w[webhook].freeze

      module_function

      # @param extra [Array<String>] channels to force on regardless of
      #   configuration — `portage buy --wait` forces `terminal` in plain
      #   (non-`--json`) mode, so the shopper sees a line when it settles
      #   even with nothing configured.
      # @return [Array<String>]
      def resolve(override: nil, config: Config.load, extra: [])
        raw = Setting.resolve(override: override, env: ENV_VAR, config: config, config_key: CONFIG_KEY)
        configured = raw.nil? ? DEFAULT : raw.to_s.split(",").map(&:strip)
        ((configured & CHANNELS) + extra).uniq
      end
    end
  end
end
