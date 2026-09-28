require_relative "config"
require_relative "setting"

module Portage
  module Cli
    # `portage buy --handoff-target` (docs/plans/buy-skill-and-local-browser.md
    # Phase 5): which of the four hand-off targets a dead-end checkout_url
    # goes to. Same Setting precedence as CheckoutHandoff/Notifier — a
    # per-invocation override beats PORTAGE_HANDOFF_TARGET, which beats
    # ~/.portage/config.json's "handoff_target" — and defaults to "default"
    # (today's CheckoutHandoff auto-open behavior) when nothing is set at
    # any level.
    #
    # Raises ArgumentError on anything else, so `Cli.run_buy` can treat a
    # bad value as a usage error the same way it already does for a bad
    # --min-confidence (see Cli.confidence_check) — built once, up front,
    # before a checkout is ever attempted.
    class HandoffTarget
      ENV_VAR = "PORTAGE_HANDOFF_TARGET".freeze
      CONFIG_KEY = "handoff_target".freeze
      DEFAULT = "default".freeze
      KNOWN_KINDS = %w[default print profile].freeze
      AGENT_PATTERN = /\Aagent:(.+)\z/

      attr_reader :kind, :agent_name

      def initialize(override: nil, config: Config.load)
        value = Setting.resolve(override: override, env: ENV_VAR, config: config, config_key: CONFIG_KEY)
        value = value.to_s.strip
        parse!(value.empty? ? DEFAULT : value)
      end

      def default? = @kind == "default"
      def print? = @kind == "print"
      def profile? = @kind == "profile"
      def agent? = @kind == "agent"

      # `agent:<name>`'s own label for a report/dispatch — "agent:<name>"
      # for an agent target, or just the kind otherwise.
      def label = agent? ? "agent:#{agent_name}" : @kind

      private

      def parse!(value)
        if KNOWN_KINDS.include?(value)
          @kind = value
          return
        end

        match = AGENT_PATTERN.match(value)
        unless match
          raise ArgumentError, "Unknown --handoff-target #{value.inspect} — use default, print, profile, " \
                               "or agent:<name>."
        end

        @kind = "agent"
        @agent_name = match[1]
      end
    end
  end
end
