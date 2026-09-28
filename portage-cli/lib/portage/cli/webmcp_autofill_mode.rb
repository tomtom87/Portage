require_relative "config"
require_relative "setting"

module Portage
  module Cli
    # docs/plans/webmcp-universal-outbound.md Phase 3 — the opt-in gate in
    # front of filling the store's own checkout page. Off by default: only
    # `--autofill` (a per-run CLI flag, forwarded to `Buy.new(autofill:)`)
    # or `PORTAGE_WEBMCP_AUTOFILL=approve` / config.json's
    # `"webmcp_autofill": "approve"` turn it on. Same Setting precedence
    # everywhere else in this gem uses (WebmcpCheckoutMode, HandoffSpendMode)
    # — override beats env beats config — except the override here is a
    # boolean (the flag is either passed or it isn't), while the env/config
    # level is a literal string, `"approve"`, not truthy-string parsing
    # (Setting.flag?'s "1"/"true"/"yes"): a plan that could be
    # `PORTAGE_WEBMCP_AUTOFILL=true` by accident from some other truthy
    # convention shouldn't silently turn on typing into a checkout page.
    #
    # Turning this gate on is still only half of Phase 3's opt-in: even
    # approved, nothing is typed until the shopper also approves the exact
    # field/value pairs in WebmcpAutofillConfirm's own prompt.
    module WebmcpAutofillMode
      ENV_VAR = "PORTAGE_WEBMCP_AUTOFILL".freeze
      CONFIG_KEY = "webmcp_autofill".freeze
      APPROVE = "approve".freeze

      module_function

      # @param override [Boolean, nil] --autofill's value: true when the
      #   flag was passed, nil otherwise (there's no --no-autofill; the flag
      #   only ever turns this on, same as --dry-run/--yes elsewhere in Buy).
      def approved?(override: nil, config: Config.load)
        return true if override == true

        Setting.resolve(env: ENV_VAR, config: config, config_key: CONFIG_KEY).to_s.strip.downcase == APPROVE
      end
    end
  end
end
