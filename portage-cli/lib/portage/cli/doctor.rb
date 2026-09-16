require "portage/ucp"

module Portage
  module Cli
    # `portage doctor` — sanity-checks a seller's Portage::Ucp setup for the
    # footguns nothing else catches automatically: an authenticator/rate
    # limiter left at their fail-safe default (Configuration#initialize),
    # no signing keys or payment handlers configured, and (when an adapter
    # class is given) a capability that's only half-implemented — one action
    # overridden, its siblings still raising Adapter's NotImplementedError.
    # Runs against whatever `Portage::Ucp.configuration` looks like in this
    # process, so a host app passes `--require` to load its own initializer
    # first (Rails: `--require ./config/environment`).
    class Doctor
      Finding = Struct.new(:check, :message, keyword_init: true)

      def initialize(adapter_class: nil)
        @adapter_class = adapter_class
      end

      def call
        [
          authenticator_finding,
          rate_limiter_finding,
          signing_keys_finding,
          payment_handlers_finding,
          *capability_findings
        ].compact
      end

      private

      def config = Portage::Ucp.configuration

      def authenticator_finding
        return unless config.authenticator.is_a?(Portage::Ucp::UnconfiguredAuthenticator)

        Finding.new(check: "authenticator",
                    message: "UnconfiguredAuthenticator is still in place — every mutating capability " \
                             "call is rejected. Set config.authenticator.")
      end

      def rate_limiter_finding
        return unless config.rate_limiter.is_a?(Portage::Ucp::NullRateLimiter)

        Finding.new(check: "rate_limiter",
                    message: "NullRateLimiter is still in place — no rate limiting is applied. " \
                             "Set config.rate_limiter if that's not intentional.")
      end

      def signing_keys_finding
        return unless Array(config.signing_keys).empty?

        Finding.new(check: "signing_keys", message: "No signing_keys configured — the manifest ships unsigned.")
      end

      def payment_handlers_finding
        return unless Array(config.payment_handlers).empty?

        Finding.new(check: "payment_handlers",
                    message: "No payment_handlers configured — buyers can't complete a " \
                             "payment-enrolled checkout.")
      end

      # Only action-based capabilities (predicate-based ones like discount/
      # fulfillment need a live instance to call their predicate method, and
      # doctor never instantiates an arbitrary adapter — it may need real
      # credentials to construct).
      def capability_findings
        return [] unless @adapter_class

        Portage::Ucp::Capabilities::ALL.filter_map { |capability| partial_capability_finding(capability) }
      end

      def partial_capability_finding(capability)
        return if capability.actions.nil? || capability.actions.empty?

        overridden = capability.actions.values.select { |method_name| overridden?(method_name) }
        return if overridden.empty? || overridden.length == capability.actions.length

        Finding.new(check: "capability:#{capability.name}",
                    message: "#{capability.name} implements #{overridden.length}/#{capability.actions.length} " \
                             "actions (#{overridden.join(', ')}) — the rest still raise NotImplementedError.")
      end

      def overridden?(method_name)
        @adapter_class.instance_method(method_name).owner != Portage::Ucp::Adapter
      end
    end
  end
end
