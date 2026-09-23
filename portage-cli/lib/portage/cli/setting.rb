module Portage
  module Cli
    # How portage-cli resolves a standing preference, in one place
    # (docs/plans/checkout-handoff-delivery.md open decision #1): a
    # per-invocation override (a flag) beats its PORTAGE_* env var, which
    # beats its ~/.portage/config.json key (Config). CheckoutHandoff,
    # Notifier, Buy and ConfidenceCheck all read their settings through it.
    #
    # nil or a blank string counts as unset at every level, so an exported
    # but empty `PORTAGE_AUTO_OPEN_CHECKOUT=` falls through to config.json
    # rather than silently meaning "off".
    module Setting
      TRUE_VALUES = %w[1 true yes].freeze

      module_function

      # @param override [Object, nil] the flag's value, nil when not passed.
      # @param env [String, nil] the env var's name.
      # @param config [Config, nil]
      # @param config_key [String, nil]
      # @return [Object, nil] the value from the first level that's set.
      def resolve(override: nil, env: nil, config: nil, config_key: nil)
        return override if set?(override)

        from_env = env && ENV.fetch(env, nil)
        return from_env if set?(from_env)

        from_config = config_key && config&.get(config_key)
        from_config if set?(from_config)
      end

      # The same precedence, read as yes/no: true, or a string in
      # TRUE_VALUES (any case). Anything else, unset included, is no.
      def flag?(**)
        TRUE_VALUES.include?(resolve(**).to_s.strip.downcase)
      end

      def set?(value)
        !(value.nil? || (value.is_a?(String) && value.strip.empty?))
      end
      private_class_method :set?
    end
  end
end
