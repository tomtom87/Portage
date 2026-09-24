require "portage/ucp"
require "uri"
require_relative "confidence_check"
require_relative "user_agent"
require_relative "proxy_settings"

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

      def initialize(adapter_class: nil, proxy_settings: ProxySettings.new)
        @adapter_class = adapter_class
        @proxy_settings = proxy_settings
      end

      def call
        [
          authenticator_finding,
          rate_limiter_finding,
          signing_keys_finding,
          payment_handlers_finding,
          decision_backend_finding,
          user_agent_finding,
          proxy_finding,
          *proxy_doctor_findings,
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

      # The confidence gate's backend, checked only once one is selected
      # (PORTAGE_DECISION_BACKEND): the gate is off by default, and a
      # missing key for a backend nobody chose is noise. Once one is
      # selected, anything short of ready holds every `--yes` purchase, so
      # it's flagged here rather than first surfacing mid-checkout. Covers
      # the gem not being installed, an unknown backend name, a missing
      # JEV_API_KEY, a missing Laya bridge, and a bad PORTAGE_MIN_CONFIDENCE.
      def decision_backend_finding
        problem = ConfidenceCheck.new.configuration_problem
        problem && Finding.new(check: "decision_backend",
                               message: "#{problem} — until then every `portage buy --yes` is held for the shopper.")
      rescue ArgumentError => e
        Finding.new(check: "decision_backend", message: e.message)
      end

      # PORTAGE_USER_AGENT / config.json's "user_agent" (UserAgent) is sent
      # as-is on every outbound request. Net::HTTP raises ArgumentError on a
      # header value containing CR/LF rather than send it, so a bad override
      # would otherwise surface for the first time mid-checkout instead of
      # here.
      def user_agent_finding
        value = Portage::Cli::UserAgent.value
        return unless value =~ /[\r\n]/

        Finding.new(check: "user_agent",
                    message: "Configured User-Agent (PORTAGE_USER_AGENT or user_agent in " \
                             "~/.portage/config.json) contains a newline — every outbound request will " \
                             "raise instead of sending.")
      end

      # Phase 0 of docs/plans/proxy-support.md: every raw Net::HTTP.start call
      # site in portage-cli/portage-ucp/the adapter gems resolves its proxy
      # from Ruby stdlib's own `:ENV` default, which — confirmed against a
      # real local proxy — only ever reads `http_proxy`/`HTTP_PROXY`, for
      # *both* http and https targets, and never `https_proxy`/`HTTPS_PROXY`.
      # That's surprising enough (and the failure silent enough — requests
      # just go direct) that it's worth a doctor check on both sides: report
      # the effective proxy when one is actually active, and flag the classic
      # footgun of setting only HTTPS_PROXY and expecting it to do anything
      # here.
      def proxy_finding
        http_proxy = ENV["http_proxy"] || ENV.fetch("HTTP_PROXY", nil)
        return https_only_proxy_finding if !http_proxy && https_env_proxy_set?

        return unless http_proxy

        Finding.new(check: "proxy",
                    message: "Outbound requests proxy through #{redact_proxy_url(http_proxy)} " \
                             "(from #{ENV['http_proxy'] ? 'http_proxy' : 'HTTP_PROXY'}, used for both http:// " \
                             "and https:// targets)#{no_proxy_suffix}.")
      end

      def https_only_proxy_finding
        Finding.new(check: "proxy",
                    message: "HTTPS_PROXY/https_proxy is set but http_proxy/HTTP_PROXY is not — Ruby's " \
                             "Net::HTTP only ever reads http_proxy for its :ENV proxy mode (for both http:// " \
                             "and https:// targets), so every portage-cli/portage-ucp/adapter call site is " \
                             "proxying nothing right now. Set http_proxy (it covers https:// targets too) if " \
                             "that traffic should go through a proxy. (portage-ucp-client's own UCP/MCP tool " \
                             "calls are the one exception — they're Faraday-based and do read https_proxy.)")
      end

      def https_env_proxy_set?
        !(ENV["https_proxy"].to_s.empty? && ENV["HTTPS_PROXY"].to_s.empty?)
      end

      def no_proxy_suffix
        no_proxy = ENV["no_proxy"] || ENV.fetch("NO_PROXY", nil)
        no_proxy ? "; no_proxy=#{no_proxy}" : ""
      end

      # `http://***@host:port` — never the real credentials (see the plan's
      # "Credentials stay safe" constraint).
      def redact_proxy_url(url)
        uri = URI.parse(url.include?("://") ? url : "http://#{url}")
        userinfo = uri.userinfo ? "***@" : ""
        port = uri.port ? ":#{uri.port}" : ""
        "#{uri.scheme}://#{userinfo}#{uri.host}#{port}"
      rescue URI::InvalidURIError
        "(unparseable proxy URL)"
      end

      # Phase 2's own checks against whatever ProxySettings resolved
      # (flags/env/config.json), kept separate from proxy_finding above —
      # see ProxyDoctor's own comment for why the two don't merge.
      def proxy_doctor_findings
        ProxyDoctor.new(proxy_settings: @proxy_settings).findings
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

# Loaded after Doctor closes — ProxyDoctor calls Doctor::Finding.new, so
# Doctor has to exist first (this file requires proxy_settings, not
# proxy_doctor, at the top for exactly this reason).
require_relative "proxy_doctor"
