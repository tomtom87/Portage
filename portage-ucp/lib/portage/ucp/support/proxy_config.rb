require "uri"

module Portage
  module Ucp
    module Support
      # Phase 1 of docs/plans/proxy-support.md, open decision 1 (resolved):
      # a plain value object living in core, with zero knowledge of CLI
      # flags or `~/.portage/config.json` — portage-cli resolves those into
      # this shape in a later phase (Phase 2's `ProxySettings`) and hands it
      # to Support::Connection. Until then, `ProxyConfig.current` defaults
      # to a fully-direct config, so nothing changes for anyone who hasn't
      # built one, and specs can hand `Support::Connection.start` a
      # `proxy:` of their own without touching the global default at all.
      #
      # Holds named Profiles (any number, by name) plus a `routes` map from
      # route name (the plan's fixed categories: :store, :search, :notify,
      # :payment, :platform, :probe — or any caller-chosen name) to either a
      # profile name, an inline profile (Hash or Profile), `:direct`, or an
      # ordered chain (Array) of any of those for `forward -> forward -> ...`
      # nesting (see Support::Connection). A route not listed falls back to
      # the `default` route; no `default` means direct — same "no
      # configuration is safe configuration" posture doctor's proxy_finding
      # already assumes for the env case.
      class ProxyConfig
        # Raised at Profile construction (config-load time, not request
        # time) for anything the plan's "Protected headers" section forbids
        # outright — see Profile#initialize below.
        class ConfigError < Portage::Ucp::Error; end

        # Never overridable by proxy_headers/forward_headers config — see
        # the plan's "Headers" section. `User-Agent` is UserAgent's alone
        # (portage-cli), `Authorization` and the payment-token header would
        # hand a proxy the exact credentials PCI/OAuth boundaries exist to
        # protect, and `X-Shopify-*-Access-Token` covers Shopify's whole
        # family of platform tokens (Admin, Storefront, and any future
        # variant) rather than naming each one.
        PROTECTED_HEADER_NAMES = %w[Authorization User-Agent X-Payment-Token].freeze
        PROTECTED_HEADER_PATTERN = /\AX-Shopify-.*-Access-Token\z/i

        def self.protected_header?(name)
          name = name.to_s
          PROTECTED_HEADER_NAMES.any? { |protected_name| protected_name.casecmp?(name) } ||
            name.match?(PROTECTED_HEADER_PATTERN)
        end

        # @raise [ConfigError] naming the offending header, rather than
        # silently dropping it — "silently accepting it would be worse"
        # (the plan, verbatim).
        def self.validate_headers!(headers)
          headers.each_key do |name|
            next unless protected_header?(name)

            raise ConfigError,
                  "#{name} is a protected header and cannot be set via proxy_headers/forward_headers " \
                  "(Authorization, User-Agent, X-Shopify-*-Access-Token, and X-Payment-Token are never " \
                  "overridable by proxy config)"
          end
          headers.each_with_object({}) { |(key, value), out| out[key.to_s] = value }
        end

        # A hostname matches when it equals an entry, is a subdomain of one
        # (leading-dot entries match subdomains only, bare entries match
        # both the bare host and any subdomain — the plan's simplified
        # "hostname suffix match, exact match, *" rule, deliberately not a
        # byte-for-byte replay of Phase 0's stdlib-quirks findings, which
        # describe `URI::Generic#use_proxy?`'s own asymmetric behavior for
        # the *env*-proxy fallback path, not this configured list), or the
        # list contains a bare `*`.
        def self.host_matches?(host, list)
          host = host.to_s.downcase
          return false if host.empty?

          Array(list).any? do |entry|
            entry = entry.to_s.strip.downcase
            next false if entry.empty?
            next true if entry == "*"

            bare = entry.sub(/\A\./, "")
            host == bare || host.end_with?(".#{bare}")
          end
        end

        # One hop: a real forward/gateway proxy, or `:direct` (no proxying
        # at all — what an unlisted route or a no_proxy match resolves to).
        class Profile
          MODES = %i[direct forward gateway].freeze

          attr_reader :mode, :url, :proxy_headers, :ca_file, :target_header, :target_param

          # @param mode [Symbol] :direct, :forward, or :gateway
          # @param url [String, nil] the proxy/gateway's own URL
          #   (`http://user:pass@host:port` for forward, the gateway's base
          #   URL for gateway) — required for anything but :direct.
          # @param proxy_headers [Hash] sent only to the proxy — on the
          #   CONNECT request (forward) or added to the request the gateway
          #   itself receives (gateway). Never sent to the real target.
          #   Refused at construction time when it names a protected header.
          # @param ca_file [String, nil] a PEM file trusted in addition to
          #   the system store, for a TLS-intercepting corporate proxy.
          # @param target_header [String, nil] gateway mode: carry the real
          #   target URL in this request header.
          # @param target_param [String, nil] gateway mode: carry the real
          #   target URL in this query parameter instead of a header.
          #   Mutually exclusive with target_header in practice — when
          #   neither is set, gateway mode falls back to path-prefix mode
          #   (`{base}/{host}{path}`).
          def initialize(mode: :forward, url: nil, proxy_headers: {}, ca_file: nil,
                         target_header: nil, target_param: nil)
            @mode = mode.to_sym
            raise ConfigError, "unknown proxy mode #{@mode.inspect}" unless MODES.include?(@mode)
            raise ConfigError, "proxy profile mode #{@mode.inspect} needs a url" if !direct? && url.to_s.empty?

            @url = url
            @proxy_headers = ProxyConfig.validate_headers!(proxy_headers || {})
            @ca_file = ca_file
            @target_header = target_header
            @target_param = target_param
          end

          def direct? = @mode == :direct
          def forward? = @mode == :forward
          def gateway? = @mode == :gateway

          # @return [URI, nil] parsed once and memoized — nil for :direct.
          def proxy_uri
            return nil unless @url

            @proxy_uri ||= URI(@url)
          end

          DIRECT = new(mode: :direct)
        end

        attr_reader :no_proxy

        # @param profiles [Hash{String,Symbol => Profile,Hash}] named
        #   profiles a route can reference by name.
        # @param routes [Hash{String,Symbol => Object}] route name -> a
        #   profile name/Hash/Profile, `:direct`, or an Array chain of any
        #   of those. A route not present falls back to "default"; no
        #   "default" entry means direct.
        # @param no_proxy [Array<String>] see .host_matches? — matched
        #   before route resolution, and (Support::Connection's job, not
        #   this class's) before the env-proxy fallback too.
        def initialize(profiles: {}, routes: {}, no_proxy: [])
          @profiles = {}
          profiles.each { |name, spec| @profiles[name.to_s] = coerce_profile(spec) }
          @routes = routes.transform_keys(&:to_s)
          @no_proxy = Array(no_proxy)
        end

        # The process-wide default until portage-cli (Phase 2) sets its own
        # resolved config. Specs never need to touch this — pass `proxy:`
        # directly to Support::Connection.start instead — but it exists so
        # a host app/CLI has exactly one place to plug in a real config,
        # the same shape as `Portage::Ucp.configuration`.
        def self.direct
          @direct ||= new
        end

        class << self
          attr_writer :current
        end

        def self.current
          @current ||= direct
        end

        # @return [Array<Profile>] the chain to dial through for `route`
        #   when the target is `host` — length 1 for every case but a
        #   configured multi-hop chain. `[Profile::DIRECT]` means "no
        #   configured proxy applies" (either a no_proxy match, or the
        #   route resolving to a literal `:direct`); Support::Connection
        #   only layers its env-proxy fallback on top when #configured?
        #   says the route wasn't touched by config at all — a route
        #   explicitly set to `:direct` (the plan's payment-route default)
        #   always wins over the ambient env, same as a route pointed at a
        #   real profile would.
        def chain_for(route, host:)
          return [Profile::DIRECT] if no_proxy_match?(host)

          spec = resolved_spec(route)
          return [Profile::DIRECT] if spec.nil?

          chain = spec.is_a?(Array) ? spec : [spec]
          chain.map { |entry| coerce_profile(entry) }
        end

        # @return [Boolean] true when `route` (or a "default" entry) has any
        #   value at all in `routes` — including an explicit `:direct`,
        #   which still counts as "configured" (see #chain_for above).
        def configured?(route)
          !resolved_spec(route).nil?
        end

        def no_proxy_match?(host)
          self.class.host_matches?(host, @no_proxy)
        end

        private

        def resolved_spec(route)
          key = route.to_s
          @routes.key?(key) ? @routes[key] : @routes["default"]
        end

        def coerce_profile(spec)
          case spec
          when Profile then spec
          when :direct, "direct" then Profile::DIRECT
          when Hash then Profile.new(**symbolize_keys(spec))
          when String, Symbol
            @profiles[spec.to_s] || raise(ConfigError, "unknown proxy profile #{spec.inspect}")
          else
            raise ConfigError, "invalid proxy profile #{spec.inspect}"
          end
        end

        def symbolize_keys(hash)
          hash.each_with_object({}) { |(key, value), out| out[key.to_sym] = value }
        end
      end
    end
  end
end
