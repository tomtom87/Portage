require "uri"
require_relative "config"
require_relative "setting"

module Portage
  module Cli
    # Phase 1 of docs/plans/checkout-handoff-delivery.md — auto-opens a
    # checkout_url in the shopper's browser when a `Buy` dead-end
    # (escalation, permission denied, no payment token) hands off a link
    # rather than completing the purchase itself.
    #
    # Default off. Precedence for the toggle (open decision #1, resolved,
    # see Setting): a per-invocation `auto_open:` override (portage buy
    # --auto-open / --no-auto-open) beats PORTAGE_AUTO_OPEN_CHECKOUT, which
    # beats ~/.portage/config.json's "auto_open_checkout" (Config).
    #
    # No new gem for the actual open — every other shell-out in this repo
    # (PaymentMethods::KeychainBackend, SecretServiceBackend) hand-rolls
    # `system` rather than pulling in launchy for something the OS already
    # provides. `system(cmd, url)` (array form, never an interpolated
    # string) so a merchant-controlled checkout_url can't inject into a
    # shell.
    class CheckoutHandoff
      ENV_VAR = "PORTAGE_AUTO_OPEN_CHECKOUT".freeze
      CONFIG_KEY = "auto_open_checkout".freeze

      def initialize(auto_open: nil, config: Config.load)
        @override = auto_open
        @config = config
      end

      def auto_open?
        Setting.flag?(override: @override, env: ENV_VAR, config: @config, config_key: CONFIG_KEY)
      end

      # @return [Boolean] whether the browser was actually opened.
      def call(checkout_url)
        return false unless auto_open? && https?(checkout_url)

        open_browser(checkout_url)
      end

      private

      def https?(url)
        URI.parse(url).scheme == "https"
      rescue URI::InvalidURIError
        false
      end

      def open_browser(url)
        command = platform_command
        return false unless command

        !!system(command, url)
      rescue StandardError => e
        warn "portage: couldn't open #{url} (#{e.message})"
        false
      end

      def platform_command
        case RbConfig::CONFIG["host_os"]
        when /darwin/i then "open"
        when /linux|bsd/i then "xdg-open"
        when /mswin|mingw|cygwin/i then "start"
        end
      end
    end
  end
end
