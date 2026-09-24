require_relative "config"
require_relative "setting"

module Portage
  module Cli
    # docs/plans/handoff-reconcile.md Phase 3, decision 5 — the ceiling on
    # `portage buy --wait`'s poll loop (see HandoffWaiter). Same Setting
    # precedence as HandoffSpendMode/CheckoutHandoff: flag (--wait-timeout)
    # > PORTAGE_HANDOFF_WAIT_TIMEOUT > config.json's "handoff_wait_timeout".
    # Unset is 30 minutes; `off` (or `0`) removes the ceiling entirely, so
    # the wait runs until the checkout's own `expires_at` instead.
    module HandoffWaitTimeout
      ENV_VAR = "PORTAGE_HANDOFF_WAIT_TIMEOUT".freeze
      CONFIG_KEY = "handoff_wait_timeout".freeze
      DEFAULT = 1800 # 30 minutes.
      OFF_VALUES = %w[off 0].freeze
      DURATION_UNITS = { "s" => 1, "m" => 60, "h" => 3600 }.freeze

      module_function

      # @return [Integer, nil] seconds to wait, or nil for "no ceiling" —
      #   the caller then waits only on the checkout's own `expires_at`.
      def resolve(override: nil, config: Config.load)
        raw = Setting.resolve(override: override, env: ENV_VAR, config: config, config_key: CONFIG_KEY)
        raw.nil? ? DEFAULT : parse(raw)
      end

      def parse(raw)
        text = raw.to_s.strip.downcase
        return nil if OFF_VALUES.include?(text)

        seconds = parse_duration(text)
        seconds&.positive? ? seconds : DEFAULT
      end

      # Accepts a bare integer (seconds) or a suffixed duration (`30m`,
      # `1h`, `45s`) — `--wait-timeout` is a human-typed flag, not a raw
      # second count like `--rolling-window-seconds`.
      def parse_duration(text)
        return text.to_i if text.match?(/\A\d+\z/)

        match = text.match(/\A(\d+)([smh])\z/)
        return nil unless match

        match[1].to_i * DURATION_UNITS.fetch(match[2])
      end
    end
  end
end
