require "json"
require "uri"
require "portage/ucp"
require_relative "config"
require_relative "proxy_settings/password_ref"

module Portage
  module Cli
    # Phase 2 of docs/plans/proxy-support.md: resolves `--proxy*` flags,
    # `PORTAGE_PROXY*` env vars, and `~/.portage/config.json`'s "proxy"
    # section into the `Portage::Ucp::Support::ProxyConfig` Phase 1 already
    # built — core stays exactly as ignorant of config.json as open decision
    # 1 says it should (docs/plans/proxy-support.md). One instance per CLI
    # invocation, same "resolved fresh, not frozen at load time" posture as
    # UserAgent/Notifier's own Setting-backed resolution.
    #
    # Precedence is *per field*, not whole-object: a bare `--proxy URL`
    # overrides only `default.url`, leaving config.json's `default.no_proxy`,
    # `routes`, `chains`, etc. exactly as configured. See #build_default_spec
    # and the `resolve3` calls throughout for where each field's own
    # flag > env > config.json chain lives.
    #
    # The `payment` route is force-set to `:direct` unless the caller (flag,
    # or config.json's `routes.payment`) names a proxy for it explicitly —
    # the plan's "payment route defaults to direct" constraint isn't
    # enforced by core's ProxyConfig#resolved_spec itself (an unlisted route
    # falls back to "default" same as any other), so this class is where it
    # actually holds. That also means portage-cli's own payment traffic no
    # longer inherits a bare $http_proxy/$https_proxy the way every other
    # unconfigured route still does (see #build_routes) — a deliberate
    # narrowing to protect payment tokens from an egress proxy nobody meant
    # to hand them to, not a bug.
    class ProxySettings
      # Raised instead of Portage::Ucp::Support::ProxyConfig::ConfigError —
      # a CLI-level config problem (a bad flag, malformed config.json, an
      # unresolvable password_ref) should read as portage-cli's own error,
      # not leak a bare core exception class/message at the command line.
      class ConfigError < StandardError; end

      ENV_URL = "PORTAGE_PROXY".freeze
      ENV_MODE = "PORTAGE_PROXY_MODE".freeze
      ENV_NO_PROXY = "PORTAGE_NO_PROXY".freeze
      ENV_CA = "PORTAGE_PROXY_CA".freeze
      ENV_HEADERS = "PORTAGE_PROXY_HEADERS".freeze

      ENV_INTERPOLATION = /\$\{([A-Za-z_][A-Za-z0-9_]*)\}/

      ProxyConfig = Portage::Ucp::Support::ProxyConfig

      # Adds every proxy flag to `parser`, accumulating into `target` under
      # the keys #initialize's `flags:` expects — one call site shared by
      # every network command's own option parser (buy/find/compare/doctor/
      # payment enroll), per the plan's "sharing one helper".
      def self.add_options(parser, target)
        init_array_flags!(target)
        add_scalar_options(parser, target)
        add_repeatable_options(parser, target)
      end

      def self.init_array_flags!(target)
        target[:proxy_headers] ||= []
        target[:proxy_routes] ||= []
        target[:proxy_passthrough] ||= []
      end

      def self.add_scalar_options(parser, target)
        parser.on("--proxy URL") { |v| target[:proxy] = v }
        parser.on("--proxy-mode MODE") { |v| target[:proxy_mode] = v }
        parser.on("--no-proxy HOSTS") { |v| target[:no_proxy] = v }
        parser.on("--proxy-chain CHAIN") { |v| target[:proxy_chain] = v }
        parser.on("--proxy-ca FILE") { |v| target[:proxy_ca] = v }
        parser.on("--no-env-proxy") { target[:no_env_proxy] = true }
      end

      def self.add_repeatable_options(parser, target)
        parser.on("--proxy-header HEADER") { |v| target[:proxy_headers] << v }
        parser.on("--proxy-route ROUTE") { |v| target[:proxy_routes] << v }
        parser.on("--proxy-passthrough HEADER") { |v| target[:proxy_passthrough] << v }
      end

      # @param value [String] a header value, or any other config string.
      def self.expand_env(value)
        return value unless value.is_a?(String)

        value.gsub(ENV_INTERPOLATION) { ENV.fetch(::Regexp.last_match(1), "") }
      end

      def self.expand_env_hash(hash)
        hash.to_h { |key, value| [key.to_s, expand_env(value)] }
      end

      def self.parse_header_flag(raw)
        name, value = raw.to_s.split(":", 2)
        raise ConfigError, "--proxy-header must be \"Name: value\" (got #{raw.inspect})" unless name && value

        [name.strip, value.strip]
      end

      def self.resolve(flags: {}, config: Config.load) = new(flags: flags, config: config).resolve

      def initialize(flags: {}, config: Config.load)
        @flags = flags
        @config = config
        @proxy_json = config.get("proxy") || {}
      end

      # @return [Portage::Ucp::Support::ProxyConfig]
      # @raise [ConfigError]
      def resolve
        @resolve ||= build!
      end

      # @return [Hash] route name -> resolved spec (a ProxyConfig::Profile,
      #   or an Array chain of them — Profile::DIRECT for "direct") — the
      #   same shape #resolve handed to ProxyConfig.new, kept around for
      #   `doctor`'s effective-routing display.
      def routes
        resolve
        @routes
      end

      # @return [Hash] `{"add" => {...}, "strip" => [...]}` from
      #   config.json's `proxy.default.forward_headers`, ${ENV}-expanded and
      #   protected-header-checked — parsed and stored, matching how the
      #   plan's `passthrough`/`inbound` sections are handled below, since
      #   core's Support::Connection has nowhere to apply an add/strip
      #   rewrite to the real target yet (that's request-building work at
      #   every call site, out of Phase 2's "CLI config + flags + doctor"
      #   scope — see the handoff report).
      def forward_headers
        resolve
        @forward_headers
      end

      # @return [Hash] config.json's `proxy.passthrough`, verbatim (Phase 3
      #   reads this; Phase 2 only parses and stores it).
      def passthrough
        resolve
        @passthrough
      end

      # @return [Hash] config.json's `proxy.inbound`, verbatim (Phase 3
      #   reads this; Phase 2 only parses and stores it).
      def inbound
        resolve
        @inbound
      end

      def no_env_proxy? = !!@flags[:no_env_proxy]

      private

      def build!
        @default_spec = build_default_spec
        @default_spec = parse_chain_flag(@flags[:proxy_chain]) if present?(@flags[:proxy_chain])
        @routes = build_routes
        @forward_headers = forward_headers_meta
        @passthrough = stringify(@proxy_json["passthrough"] || {})
        @inbound = stringify(@proxy_json["inbound"] || {})
        ProxyConfig.new(routes: @routes, no_proxy: no_proxy_list)
      rescue ProxyConfig::ConfigError => e
        raise ConfigError, "invalid proxy configuration: #{e.message}"
      end

      # --- default profile (the flag/env/config.json "default.*" fields) --

      def build_default_spec
        url = resolve3(@flags[:proxy], ENV_URL, @proxy_json.dig("default", "url"))
        return nil unless present?(url)

        raw = @proxy_json["default"] || {}
        url = apply_password_ref(url, raw["password_ref"])
        mode = resolve3(@flags[:proxy_mode], ENV_MODE, raw["mode"])
        ca_file = resolve3(@flags[:proxy_ca], ENV_CA, raw["ca_file"])
        build_profile(raw, url: url, mode: mode, proxy_headers: default_proxy_headers, ca_file: ca_file)
      end

      def default_proxy_headers
        headers = self.class.expand_env_hash(stringify(@proxy_json.dig("default", "proxy_headers") || {}))
        headers.merge!(env_headers)
        headers.merge!(flag_headers)
        headers
      end

      def env_headers
        raw = ENV.fetch(ENV_HEADERS, nil)
        return {} unless present?(raw)

        parsed = JSON.parse(raw)
        parsed.is_a?(Hash) ? stringify(parsed) : {}
      rescue JSON::ParserError => e
        raise ConfigError, "#{ENV_HEADERS} is not valid JSON: #{e.message}"
      end

      def flag_headers
        Array(@flags[:proxy_headers]).to_h { |raw| self.class.parse_header_flag(raw) }
      end

      # --- forward_headers (parsed + protected-header-checked, not yet
      # applied to any outgoing request — see #forward_headers above) ------

      def forward_headers_meta
        raw = @proxy_json.dig("default", "forward_headers") || {}
        add = self.class.expand_env_hash(stringify(raw["add"] || {}))
        strip = Array(raw["strip"]).map(&:to_s)
        ProxyConfig.validate_headers!(add)
        refuse_protected_strip!(strip)
        { "add" => add, "strip" => strip }
      end

      def refuse_protected_strip!(strip)
        offender = strip.find { |name| ProxyConfig.protected_header?(name) }
        return unless offender

        raise ProxyConfig::ConfigError,
              "#{offender} is a protected header and cannot be stripped via forward_headers"
      end

      # --- no_proxy ---------------------------------------------------

      def no_proxy_list
        flag = @flags[:no_proxy]
        return split_list(flag) if present?(flag)

        env = ENV.fetch(ENV_NO_PROXY, nil)
        return split_list(env) if present?(env)

        Array(@proxy_json.dig("default", "no_proxy"))
      end

      def split_list(value) = value.to_s.split(",").map(&:strip).reject(&:empty?)

      # --- routes -------------------------------------------------------

      def build_routes
        routes = {}
        @proxy_json.fetch("routes", {}).each { |route, spec| routes[route.to_s] = resolve_route_spec(spec) }
        routes["default"] = @default_spec if @default_spec
        Array(@flags[:proxy_routes]).each { |raw| apply_route_flag!(routes, raw) }
        routes["payment"] = ProxyConfig::Profile::DIRECT unless routes.key?("payment")
        routes["default"] = ProxyConfig::Profile::DIRECT if no_env_proxy? && !routes.key?("default")
        routes
      end

      def resolve_route_spec(spec)
        case spec
        when Hash then resolve_route_hash(spec)
        when Array then spec.map { |hop| resolve_route_spec(hop) }
        when String then resolve_route_string(spec)
        else raise ConfigError, "invalid proxy route value #{spec.inspect}"
        end
      end

      def resolve_route_hash(spec)
        spec["chain"] ? resolve_chain_name(spec["chain"]) : resolve_inline_profile(spec)
      end

      def resolve_route_string(spec)
        return ProxyConfig::Profile::DIRECT if spec == "direct"
        return @default_spec || ProxyConfig::Profile::DIRECT if spec == "default"
        return resolve_inline_profile("url" => spec) if spec.include?("://")

        resolve_chain_name(spec)
      end

      def resolve_chain_name(name)
        chain = @proxy_json.dig("chains", name)
        raise ConfigError, "unknown proxy profile or chain #{name.inspect}" unless chain

        Array(chain).map { |hop| resolve_inline_profile(hop) }
      end

      def resolve_inline_profile(raw)
        url = apply_password_ref(raw["url"], raw["password_ref"])
        headers = self.class.expand_env_hash(stringify(raw["proxy_headers"] || {}))
        build_profile(raw, url: url, mode: raw["mode"], proxy_headers: headers)
      end

      def apply_route_flag!(routes, raw)
        route, value = raw.to_s.split("=", 2)
        raise ConfigError, "--proxy-route must be ROUTE=VALUE (got #{raw.inspect})" unless route && value

        routes[route.strip] = route_value_from_flag(value.strip)
      end

      def route_value_from_flag(value)
        return ProxyConfig::Profile::DIRECT if value == "direct"
        return @default_spec || ProxyConfig::Profile::DIRECT if value == "default"
        return ProxyConfig::Profile.new(url: value) if value.include?("://")

        raise ConfigError, "--proxy-route: expected a URL or \"direct\" (got #{value.inspect})"
      end

      def parse_chain_flag(raw)
        raw.to_s.split(",").map { |hop| chain_hop_from_flag(hop.strip) }
      end

      def chain_hop_from_flag(hop)
        return ProxyConfig::Profile.new(mode: :gateway, url: hop.sub(/\Agateway\+/, "")) if hop.start_with?("gateway+")

        ProxyConfig::Profile.new(mode: :forward, url: hop)
      end

      # --- shared profile builder ------------------------------------------

      # Builds a real ProxyConfig::Profile (not a plain Hash core would only
      # coerce lazily, on first #chain_for) so a protected header or a bad
      # mode/url raises right here, at config-load time, from any of the
      # three sources (flag/env/config.json) that fed `proxy_headers` —
      # exactly what the plan's "Protected headers" constraint and this
      # phase's own step 8 require, rather than surfacing on the first real
      # request Support::Connection makes.
      def build_profile(raw, url:, mode:, proxy_headers:, ca_file: raw["ca_file"])
        kwargs = { url: url, proxy_headers: proxy_headers, ca_file: ca_file,
                   target_header: raw["target_header"], target_param: raw["target_param"] }.compact
        kwargs[:mode] = mode.to_sym if present?(mode)
        ProxyConfig::Profile.new(**kwargs)
      end

      def apply_password_ref(url, password_ref)
        return url unless present?(url) && present?(password_ref)

        secret = PasswordRef.resolve(password_ref)
        unless secret
          raise ConfigError, "proxy password_ref #{password_ref.inspect} could not be resolved from any local " \
                             "secret backend (macOS Keychain, Linux Secret Service)"
        end

        uri = URI(url)
        uri.password = URI.encode_www_form_component(secret)
        uri.to_s
      end

      # --- misc -----------------------------------------------------------

      def resolve3(flag, env_name, config_value)
        return flag if present?(flag)

        from_env = env_name && ENV.fetch(env_name, nil)
        return from_env if present?(from_env)

        config_value if present?(config_value)
      end

      def present?(value) = !(value.nil? || (value.is_a?(String) && value.strip.empty?))

      def stringify(hash) = hash.to_h { |key, value| [key.to_s, value] }
    end
  end
end
