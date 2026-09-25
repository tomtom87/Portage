require "ipaddr"
require "rack"

module Portage
  module Ucp
    module Rack
      # Phase 3 of docs/plans/proxy-support.md: the one seam every inbound
      # Rack endpoint (WebMCP's CallEndpoint, Rack::WebhookEndpoint, and
      # whatever HTTP transport fronts Mcp::Server) uses to make sense of
      # `X-Forwarded-*`/`Forwarded` (RFC 7239) headers a reverse proxy sits
      # in front of them adds.
      #
      # Fail-closed by construction: with no `trusted_proxies` configured
      # (the default — `[]`), or when the immediate socket peer isn't in
      # that list, every method here answers exactly as if no forwarded
      # headers were present at all — behavior stays unchanged from before
      # this class existed. Only once the peer itself is a trusted proxy do
      # `X-Forwarded-*`/`Forwarded` get any say in the resolved client IP,
      # scheme, or host.
      #
      # A consumer sets `trusted_proxies:` wherever it builds one of the
      # endpoints above — e.g. `CallEndpoint.new(catalog: catalog,
      # trusted_proxies: ["10.0.0.0/8"])` — naming the CIDR(s) of its own
      # load balancer/reverse proxy, never a wildcard or the public
      # Internet.
      class ForwardedRequest
        FOR_HEADER = "HTTP_X_FORWARDED_FOR".freeze
        HOST_HEADER = "HTTP_X_FORWARDED_HOST".freeze
        PROTO_HEADER = "HTTP_X_FORWARDED_PROTO".freeze
        FORWARDED_HEADER = "HTTP_FORWARDED".freeze

        # @raise [Portage::Ucp::Support::ProxyConfig::ConfigError] naming the
        #   offending header, same posture as every other protected-header
        #   check in the proxy-support plan — a passthrough list can never
        #   contain Authorization/User-Agent/X-Shopify-*-Access-Token/
        #   X-Payment-Token, checked once here at config-resolution time
        #   rather than silently dropped per-request later.
        def self.validate_passthrough!(header_names)
          offender = Array(header_names).find { |name| Support::ProxyConfig.protected_header?(name) }
          return unless offender

          raise Support::ProxyConfig::ConfigError,
                "#{offender} is a protected header and cannot be set via passthrough.headers"
        end

        # @param request [Rack::Request]
        # @param trusted_proxies [Array<String>] CIDR blocks (or bare IPs,
        #   which IPAddr treats as a /32 or /128) naming the reverse proxies
        #   allowed to set forwarding headers. Empty (the default) means
        #   fail-closed: nothing is ever trusted.
        def initialize(request, trusted_proxies: [])
          @request = request
          @trusted_proxies = Array(trusted_proxies).filter_map { |cidr| safe_ipaddr(cidr) }
        end

        # @return [Boolean] whether the immediate socket peer is one of the
        #   configured `trusted_proxies`. Reads `REMOTE_ADDR` straight off
        #   the env (`Rack::Request#get_header`, not `#ip`) rather than
        #   `request.ip` — Rack::Request#ip applies its *own*, separate
        #   `Rack::Request.ip_filter` (a process-wide default that already
        #   trusts RFC 1918/loopback ranges out of the box, independent of
        #   whatever this class is configured with) and would otherwise let
        #   Rack itself decide a header is trustworthy before this class
        #   ever gets a say. Fail-closed has to mean fail-closed regardless
        #   of Rack's own defaults.
        def peer_trusted?
          return @peer_trusted if defined?(@peer_trusted)

          @peer_trusted = trusted_ip?(raw_remote_addr)
        end

        # @return [String] the resolved client IP: standard reverse-proxy
        #   chain parsing, walking the `X-Forwarded-For`/`Forwarded` chain
        #   from the right and skipping any entry that is itself a trusted
        #   proxy — the first untrusted entry from the right is the real
        #   client. Falls back to the plain socket peer when the peer isn't
        #   trusted, no forwarding header is present, or every entry in the
        #   chain is itself a trusted proxy (nothing untrusted to report).
        def client_ip
          return strip_port(raw_remote_addr) unless peer_trusted?

          chain = forwarded_for_chain
          return strip_port(raw_remote_addr) if chain.empty?

          chain.reverse_each { |candidate| return candidate unless trusted_ip?(candidate) }
          chain.first
        end

        # @return [String] "http"/"https" — from `X-Forwarded-Proto`/
        #   `Forwarded;proto=` only when the peer is trusted, the raw
        #   connection scheme otherwise (never Rack::Request#scheme, which
        #   is itself forwarded-header-aware via Rack's own ip_filter — see
        #   #peer_trusted?).
        def scheme
          return raw_scheme unless peer_trusted?

          header_value(PROTO_HEADER) || forwarded_pair("proto") || raw_scheme
        end

        # @return [String] "host[:port]" — from `X-Forwarded-Host`/
        #   `Forwarded;host=` only when the peer is trusted, the raw `Host`
        #   header otherwise (never Rack::Request#host_with_port, same
        #   reason as #scheme above).
        def host
          return raw_host unless peer_trusted?

          header_value(HOST_HEADER) || forwarded_pair("host") || raw_host
        end

        # @return [Boolean] true only when the peer is trusted AND the
        #   forwarded host is itself in `allowed` — the gate that keeps a
        #   spoofed `X-Forwarded-Host` from ever widening what "own origin"
        #   means unless a consumer explicitly opted that host in.
        def forwarded_host_allowed?(allowed)
          return false unless peer_trusted?

          forwarded_host = header_value(HOST_HEADER) || forwarded_pair("host")
          return false if forwarded_host.nil?

          Array(allowed).map(&:to_s).include?(forwarded_host)
        end

        # @return [String] what a same-origin check should compare against
        #   for "the endpoint's own origin" — the raw scheme/host unchanged,
        #   unless `forwarded_host_allowed?(forwarded_host_allowed)` says
        #   the forwarded host is explicitly trusted for this purpose, in
        #   which case the forwarded scheme/host replace it. Never widens
        #   `allowed_origins` itself — only ever changes what "own origin"
        #   resolves to.
        def own_origin(forwarded_host_allowed: [])
          return "#{raw_scheme}://#{raw_host}" unless forwarded_host_allowed?(forwarded_host_allowed)

          "#{scheme}://#{host}"
        end

        # @param header_names [Array<String>] allowlisted inbound header
        #   names (already validated with .validate_passthrough! at
        #   config-resolution time). Returns {} from an untrusted peer, no
        #   matter what the caller asks for.
        # @return [Hash{String=>String}]
        def passthrough_headers(header_names)
          return {} unless peer_trusted?

          Array(header_names).each_with_object({}) do |name, out|
            value = @request.get_header(rack_env_key(name))
            out[name.to_s] = value if value
          end
        end

        private

        # The literal `REMOTE_ADDR`/`HTTP_HOST`/scheme env entries, bypassing
        # Rack::Request's own forwarded-aware `#ip`/`#host`/`#scheme` (see
        # #peer_trusted?'s comment) — this class makes its own trust
        # decision from `trusted_proxies` alone, never Rack's separate
        # `Rack::Request.ip_filter` default.
        def raw_remote_addr
          @request.get_header("REMOTE_ADDR").to_s
        end

        def raw_host
          host_port = @request.get_header("HTTP_HOST") ||
                      "#{@request.get_header('SERVER_NAME')}:#{@request.get_header('SERVER_PORT')}"
          strip_default_port(host_port)
        end

        def raw_scheme
          return "https" if @request.get_header("HTTPS") == "on"

          @request.get_header("rack.url_scheme") || "http"
        end

        # Mirrors Rack::Request#host_with_port's own "omit :80/:443 for the
        # matching scheme" behavior, so #own_origin's unforwarded fallback
        # matches what a plain, un-proxied request's origin has always
        # looked like.
        def strip_default_port(host_port)
          host, port = host_port.to_s.split(":", 2)
          return host_port if port.nil?
          return host if raw_scheme == "http" && port == "80"
          return host if raw_scheme == "https" && port == "443"

          host_port
        end

        def rack_env_key(name)
          "HTTP_#{name.to_s.upcase.tr('-', '_')}"
        end

        def header_value(env_key)
          value = @request.get_header(env_key)
          value.nil? || value.empty? ? nil : value
        end

        def forwarded_for_chain
          xff = header_value(FOR_HEADER)
          return xff.split(",").map { |entry| strip_port(entry) }.reject(&:empty?) if xff

          forwarded_pairs("for").map { |value| strip_port(value) }
        end

        # Extracts every `for=` value, in order (oldest hop first, per RFC
        # 7239 — each proxy appends, never prepends).
        def forwarded_pairs(key)
          raw = header_value(FORWARDED_HEADER)
          return [] unless raw

          raw.split(",").filter_map { |element| pair_from(element, key) }
        end

        # The single most-recent (right-most) `Forwarded` element's value
        # for `key` — used for scheme/host, which only the immediate
        # (trusted) hop's own element should set.
        def forwarded_pair(key)
          raw = header_value(FORWARDED_HEADER)
          return nil unless raw

          raw.split(",").filter_map { |element| pair_from(element, key) }.last
        end

        def pair_from(element, key)
          match = element.match(/#{key}="?([^;,"]+)"?/i)
          return nil unless match

          match[1].strip.sub(/\A\[/, "").sub(/\]\z/, "")
        end

        def trusted_ip?(ip_string)
          return false if @trusted_proxies.empty?

          addr = safe_ipaddr(strip_port(ip_string))
          return false unless addr

          @trusted_proxies.any? { |cidr| cidr.include?(addr) }
        end

        def safe_ipaddr(value)
          IPAddr.new(value.to_s)
        rescue IPAddr::Error
          nil
        end

        # Handles a bracketed IPv6 literal (`[::1]:8080`), a plain
        # `host:port` pair, and a bare address (IPv4, or IPv6 with no
        # port) — an unbracketed IPv6 address has more than one colon, so
        # only a single colon is ever treated as a port separator.
        def strip_port(value)
          value = value.to_s.strip
          return value if value.empty?
          return value[/\A\[(.*)\]/, 1] || value if value.start_with?("[")
          return value.split(":").first if value.count(":") == 1

          value
        end
      end
    end
  end
end
