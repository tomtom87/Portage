require_relative "config"
require_relative "setting"

module Portage
  module Cli
    # docs/plans/handoff-reconcile.md Phase 4 — how `Buy`'s optional WebMCP
    # path (see Webmcp, Buy#webmcp_flow) finishes a checkout it built in the
    # browser. Same Setting precedence as HandoffSpendMode: no CLI flag (a
    # WebMCP bridge is an injected collaborator, not something a shell
    # invocation can name), so just PORTAGE_WEBMCP_CHECKOUT_MODE >
    # config.json's "webmcp_checkout_mode". Unset, or anything not in
    # MODES, is `express_stop`, the only mode actually implemented — see
    # Buy#webmcp_token_unsupported_report for why `token` isn't yet.
    module WebmcpCheckoutMode
      ENV_VAR = "PORTAGE_WEBMCP_CHECKOUT_MODE".freeze
      CONFIG_KEY = "webmcp_checkout_mode".freeze
      MODES = %w[express_stop token].freeze
      DEFAULT = "express_stop".freeze

      module_function

      def resolve(override: nil, config: Config.load)
        mode = Setting.resolve(override: override, env: ENV_VAR, config: config, config_key: CONFIG_KEY)
        MODES.include?(mode) ? mode : DEFAULT
      end
    end
  end
end
