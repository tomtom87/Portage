require "uri"
require_relative "proxy_settings"

module Portage
  module Cli
    # Phase 2 of docs/plans/proxy-support.md's `doctor` checks for whatever
    # `ProxySettings` resolved: each configured proxy's own reachability (a
    # real CONNECT/GET through it, via Support::Connection — same code path
    # a real request would use, not a re-implementation), whether a
    # configured gateway answers at all, and the two warnings the plan calls
    # out by name (plaintext credentials sitting in config.json, an
    # intercepting proxy on the payment route). Every message redacts
    # credentials the same way Support::Connection.redact does — never the
    # real userinfo, in any finding this produces.
    #
    # Stays entirely separate from Doctor's own Phase 0 `proxy_finding`
    # (the raw $http_proxy/$https_proxy env report) rather than replacing
    # it — that one is still accurate and still worth showing for anyone who
    # hasn't touched Phase 2 flags/config.json at all.
    class ProxyDoctor
      PROBE_URI = URI("https://example.com/").freeze
      ROUTE_NAMES = %w[store search notify payment platform probe].freeze

      def initialize(proxy_settings:, config: Config.load, timeout: 5, probe_uri: PROBE_URI)
        @proxy_settings = proxy_settings
        @config = config
        @timeout = timeout
        @probe_uri = probe_uri
      end

      def findings
        [*route_summary_findings, *reachability_findings, *plaintext_credential_findings,
         *payment_intercept_findings].compact
      end

      private

      def routes = @proxy_settings.routes

      # --- effective routing, credentials redacted -----------------------

      def route_summary_findings
        return [] unless anything_configured?

        lines = ROUTE_NAMES.map { |name| "#{name}: #{effective_description(name)}" }
        [Doctor::Finding.new(check: "proxy_routes", message: lines.join("; "))]
      end

      def direct_profile = Portage::Ucp::Support::ProxyConfig::Profile::DIRECT

      def anything_configured?
        routes.any? { |name, spec| name != "payment" || spec != direct_profile }
      end

      def effective_description(name)
        return describe(routes[name]) if routes.key?(name)
        return describe(routes["default"]) if routes.key?("default")

        "unconfigured (falls back to HTTP_PROXY/HTTPS_PROXY env, or direct)"
      end

      def describe(spec)
        spec.is_a?(Array) ? spec.map { |hop| describe_hop(hop) }.join(" -> ") : describe_hop(spec)
      end

      def describe_hop(hop)
        return "direct" if hop.direct?

        "#{hop.mode} #{redact(hop.url)}"
      end

      def redact(url)
        return "(none)" unless url

        uri = URI(url)
        userinfo = uri.userinfo ? "***@" : ""
        "#{uri.scheme}://#{userinfo}#{uri.host}:#{uri.port}"
      rescue URI::InvalidURIError
        "(unparseable)"
      end

      # --- reachability ---------------------------------------------------

      def reachability_findings
        collect_profiles.filter_map { |profile| reachability_finding(profile) }
      end

      def collect_profiles
        hops = routes.values.flat_map { |spec| spec.is_a?(Array) ? spec : [spec] }
        hops.reject(&:direct?).uniq(&:url)
      end

      def reachability_finding(profile)
        probe(profile)
        nil
      rescue StandardError => e
        Doctor::Finding.new(check: "proxy_reachability",
                            message: "#{profile.mode} proxy #{redact(profile.url)} is not reachable: " \
                                     "#{e.class}: #{e.message}")
      end

      def probe(profile)
        synthetic = Portage::Ucp::Support::ProxyConfig.new(routes: { "probe" => profile })
        Portage::Ucp::Support::Connection.start(@probe_uri, route: "probe", proxy: synthetic,
                                                            open_timeout: @timeout, read_timeout: @timeout) do |http|
          http.get(@probe_uri.request_uri, {})
        end
      end

      # --- warnings ---------------------------------------------------

      def plaintext_credential_findings
        offenders = credential_bearing_profiles.select { |profile| plaintext_password?(profile) }
        return [] if offenders.empty?

        [Doctor::Finding.new(check: "proxy_credentials",
                             message: "#{offenders.length} proxy profile(s) in config.json carry a plaintext " \
                                      "password in their url — use password_ref (Keychain/Secret Service) or " \
                                      "${ENV} instead.")]
      end

      def credential_bearing_profiles
        raw = @config.get("proxy") || {}
        [raw["default"], *raw.fetch("chains", {}).values.flatten, *raw.fetch("routes", {}).values].grep(Hash)
      end

      def plaintext_password?(profile)
        uri = URI(profile["url"].to_s)
        !uri.password.to_s.empty?
      rescue URI::InvalidURIError
        false
      end

      def payment_intercept_findings
        spec = routes["payment"]
        return [] unless intercepting?(spec)

        [Doctor::Finding.new(check: "proxy_payment_intercept",
                             message: "the payment route is routed through a proxy that can see plaintext payment " \
                                      "data (ca_file set, or gateway mode): #{describe(spec)}.")]
      end

      def intercepting?(spec)
        hops = spec.is_a?(Array) ? spec : [spec]
        hops.any? { |hop| hop.gateway? || hop.ca_file }
      end
    end
  end
end
