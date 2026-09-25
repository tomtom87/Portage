require "net/http"
require "socket"
require "openssl"
require "uri"
require_relative "proxy_config"
require_relative "passthrough_context"

module Portage
  module Ucp
    module Support
      # Phase 1 of docs/plans/proxy-support.md: the one shared connection
      # seam that replaces every raw `Net::HTTP.start(uri.host, uri.port,
      # ...)` call site across core, portage-cli, and the adapter gems (see
      # the plan's "Nine call sites" list, and docs/design-log.md #44 for
      # the concrete bug this exists to fix).
      #
      # `Support::Connection.start(uri, route:, proxy:, ...) { |http| ... }`
      # is a drop-in replacement for `Net::HTTP.start(uri.host, uri.port,
      # ...) { |http| ... }` — the block receives an object that answers
      # `#request`/`#get`/`#post` the same way a real Net::HTTP does (a real
      # one, for :direct/plain-:forward; a small wrapper for :gateway and
      # for a hand-rolled CONNECT tunnel).
      #
      # Route resolution order for a given call:
      #   1. `proxy.no_proxy` (host suffix/exact/`*` match) forces direct.
      #   2. the route's configured profile/chain (ProxyConfig#chain_for).
      #   3. when neither of the above names a proxy, the *env* fallback:
      #      HTTPS_PROXY/https_proxy for an https:// target, HTTP_PROXY/
      #      http_proxy for http://, honoring NO_PROXY/no_proxy too. This is
      #      the fix for docs/design-log.md #44's headline finding —
      #      Net::HTTP's own `:ENV` proxy mode hardcodes an "http" lookup
      #      scheme and so never reads HTTPS_PROXY at all, for any target.
      #      Every call site below passes `p_addr: nil` explicitly instead
      #      of leaving Net::HTTP's `:ENV` default in place, so this env
      #      resolution — not Net::HTTP's own — is what decides.
      module Connection
        # Net::HTTP's own defaults (60s/60s) are for a human waiting on a
        # browser tab; callers that care about something tighter already
        # pass their own (e.g. Check's probe, HttpClient's 5s/30s).
        DEFAULT_OPEN_TIMEOUT = 60
        DEFAULT_READ_TIMEOUT = 60

        # Human-readable reasons for the CONNECT statuses worth naming —
        # ProxyError falls back to the bare status code for anything else.
        REASONS = {
          401 => "proxy authentication required",
          403 => "forbidden by proxy",
          407 => "proxy authentication required",
          502 => "bad gateway",
          503 => "proxy unavailable",
          504 => "gateway timeout"
        }.freeze

        # @param uri [URI, String] the real target.
        # @param route [Symbol, String] one of the plan's fixed categories
        #   (:store, :search, :notify, :payment, :platform, :probe) or any
        #   name the caller and its ProxyConfig agree on.
        # @param proxy [ProxyConfig] defaults to the process-wide
        #   ProxyConfig.current (direct until portage-cli sets one).
        # @yield [http] an object responding to #request(req), #get(path,
        #   headers), and #post(path, body, headers) — the exact surface
        #   every migrated call site already used against a plain Net::HTTP.
        # @raise [Portage::Ucp::ProxyError] on any hop failure in a
        #   hand-rolled tunnel (chained forward hops, or a single forward
        #   hop with proxy_headers set — see #route_chain).
        def self.start(uri, route:, proxy: ProxyConfig.current, open_timeout: nil, read_timeout: nil, &)
          uri = URI(uri.to_s)
          open_timeout ||= DEFAULT_OPEN_TIMEOUT
          read_timeout ||= DEFAULT_READ_TIMEOUT
          chain = route_chain(proxy, route, uri)
          dispatch(chain, uri, open_timeout: open_timeout, read_timeout: read_timeout, &)
        end

        # One hop of a kind Net::HTTP already handles itself (:direct, a
        # bare :gateway, or a :forward hop with no proxy_headers) goes
        # straight to the matching *_start; anything else — a multi-hop
        # chain, or a single :forward hop that needs custom CONNECT headers
        # (open decision 2) — goes through the hand-rolled tunnel.
        # Phase 3 of docs/plans/proxy-support.md: whatever the block
        # receives is wrapped in PassthroughHttp first, uniformly across
        # every dispatch path (direct included), so an inbound request's
        # passthrough headers/Forwarded chain (Support::PassthroughContext,
        # set by the Rack endpoint serving that request) land on outbound
        # calls no matter which route resolved. A no-op (returns the real
        # object unwrapped) outside of any PassthroughContext.with block.
        def self.dispatch(chain, uri, open_timeout:, read_timeout:, &block)
          wrapped = ->(http) { block.call(PassthroughHttp.wrap(http)) }
          if single_hop?(chain, :direct?)
            direct_start(uri, open_timeout: open_timeout, read_timeout: read_timeout, &wrapped)
          elsif single_hop?(chain, :gateway?)
            gateway_start(uri, chain.first, open_timeout: open_timeout, read_timeout: read_timeout, &wrapped)
          elsif native_forward?(chain)
            forward_start(uri, chain.first, open_timeout: open_timeout, read_timeout: read_timeout, &wrapped)
          else
            tunnel_start(uri, chain, open_timeout: open_timeout, read_timeout: read_timeout, &wrapped)
          end
        end
        private_class_method :dispatch

        def self.single_hop?(chain, predicate)
          chain.length == 1 && chain.first.public_send(predicate)
        end
        private_class_method :single_hop?

        def self.native_forward?(chain)
          single_hop?(chain, :forward?) && chain.first.proxy_headers.empty?
        end
        private_class_method :native_forward?

        # `http://***@host:port` when `uri` carries credentials, `host:port`
        # otherwise — never the real credentials, in any raised/logged
        # message this module produces (ProxyError included).
        def self.redact(uri)
          return "(unknown)" unless uri

          uri = URI(uri.to_s) unless uri.is_a?(URI::Generic)
          return "#{uri.host}:#{uri.port}" unless uri.userinfo

          "http://***@#{uri.host}:#{uri.port}"
        end

        # --- route/env resolution -------------------------------------

        # The configured route's chain, with the env-proxy fallback applied
        # only when *nothing* configured this route at all (ProxyConfig
        # #configured?) — a route explicitly set to :direct (the plan's
        # payment-route default) always wins over the ambient env, exactly
        # like a route pointed at a real profile would. A no_proxy match is
        # checked first and always wins outright, env fallback included.
        def self.route_chain(proxy, route, uri)
          return [ProxyConfig::Profile::DIRECT] if proxy.no_proxy_match?(uri.host)
          return proxy.chain_for(route, host: uri.host) if proxy.configured?(route)

          env_profile = env_fallback_profile(uri)
          env_profile ? [env_profile] : [ProxyConfig::Profile::DIRECT]
        end
        private_class_method :route_chain

        def self.env_fallback_profile(uri)
          return nil if ProxyConfig.host_matches?(uri.host, env_list("no_proxy", "NO_PROXY"))

          url = uri.scheme == "https" ? env_value("https_proxy", "HTTPS_PROXY") : env_value("http_proxy", "HTTP_PROXY")
          return nil if url.to_s.empty?

          ProxyConfig::Profile.new(mode: :forward, url: url)
        end
        private_class_method :env_fallback_profile

        # Lowercase wins when both are set — matches Phase 0's confirmed
        # stdlib behavior (docs/design-log.md #44) closely enough to keep
        # "env behaviour stays the same by default" without replaying every
        # CGI/httpoxy corner Ruby's own URI::Generic.find_proxy handles.
        def self.env_value(lower, upper)
          value = ENV.fetch(lower, nil)
          value = ENV.fetch(upper, nil) if value.to_s.empty?
          value
        end
        private_class_method :env_value

        def self.env_list(lower, upper)
          env_value(lower, upper).to_s.split(",")
        end
        private_class_method :env_list

        # --- :direct -----------------------------------------------------

        def self.direct_start(uri, open_timeout:, read_timeout:, &)
          Net::HTTP.start(uri.host, uri.port, nil, use_ssl: uri.scheme == "https",
                                                   open_timeout: open_timeout, read_timeout: read_timeout, &)
        end
        private_class_method :direct_start

        # --- :forward, single hop, no proxy_headers -----------------------

        # Net::HTTP handles a single native proxy hop itself; there's no
        # need for a hand-rolled tunnel unless proxy_headers are configured
        # (open decision 2, resolved: Net::HTTP's own CONNECT can't carry
        # extra headers) or the route names more than one hop.
        def self.forward_start(uri, profile, open_timeout:, read_timeout:, &)
          proxy_uri = profile.proxy_uri
          opts = { use_ssl: uri.scheme == "https", open_timeout: open_timeout, read_timeout: read_timeout }
          apply_ca_file!(opts, profile)
          Net::HTTP.start(uri.host, uri.port, proxy_uri.host, proxy_uri.port,
                          decoded(proxy_uri.user), decoded(proxy_uri.password), **opts, &)
        end
        private_class_method :forward_start

        def self.decoded(component)
          component && URI.decode_www_form_component(component)
        end
        private_class_method :decoded

        def self.apply_ca_file!(opts, profile)
          opts[:cert_store] = build_cert_store(profile.ca_file) if profile.ca_file
        end
        private_class_method :apply_ca_file!

        def self.build_cert_store(ca_file)
          store = OpenSSL::X509::Store.new
          store.set_default_paths
          store.add_file(ca_file)
          store
        end
        private_class_method :build_cert_store

        # --- :gateway ------------------------------------------------------

        # TLS terminates at the gateway itself — this dials the gateway's
        # own host/port directly (no proxying to reach the gateway; a
        # `forward -> gateway` chain is out of Phase 1's scope, see the
        # plan's Phase 1 spec list) and rewrites every request the caller's
        # block makes through GatewayHttp before handing it to the real
        # connection.
        def self.gateway_start(uri, profile, open_timeout:, read_timeout:, &block)
          gateway_uri = profile.proxy_uri
          opts = { use_ssl: gateway_uri.scheme == "https", open_timeout: open_timeout, read_timeout: read_timeout }
          apply_ca_file!(opts, profile)
          Net::HTTP.start(gateway_uri.host, gateway_uri.port, nil, **opts) do |http|
            block.call(GatewayHttp.new(http, profile: profile, target_uri: uri, gateway_uri: gateway_uri))
          end
        end
        private_class_method :gateway_start

        # --- hand-rolled CONNECT tunnel (chains, and single-hop forward
        # with proxy_headers) --------------------------------------------

        def self.tunnel_start(uri, chain, open_timeout:, read_timeout:, &block)
          unless chain.all?(&:forward?)
            raise ProxyConfig::ConfigError,
                  "a hand-rolled proxy chain only supports :forward hops (got #{chain.map(&:mode).inspect})"
          end

          socket = open_tunnel(chain, target_host: uri.host, target_port: uri.port,
                                      open_timeout: open_timeout, read_timeout: read_timeout)
          io = uri.scheme == "https" ? start_tls(socket, uri.host, chain.last) : socket
          bufio = Net::BufferedIO.new(io, read_timeout: read_timeout)
          conn = TunnelledHttp.new(bufio, host: uri.host, port: uri.port)
          block.call(conn)
        ensure
          close_quietly(io)
        end
        private_class_method :tunnel_start

        def self.close_quietly(io)
          io&.close
        rescue StandardError
          nil
        end
        private_class_method :close_quietly

        # Opens a raw TCP connection to hop 1, then nests a CONNECT through
        # every subsequent hop (each hop's own proxy_headers/credentials
        # on its own CONNECT) until the last hop is asked to CONNECT to the
        # real target — generalizes to any chain length, not just two.
        # @return [TCPSocket] connected all the way through to the target,
        #   not yet TLS-wrapped.
        def self.open_tunnel(chain, target_host:, target_port:, open_timeout:, read_timeout:)
          socket = dial_first_hop(chain.first, open_timeout)
          bufio = Net::BufferedIO.new(socket, read_timeout: read_timeout)

          chain.each_with_index do |hop, index|
            next_host, next_port = next_hop_target(chain, index, target_host, target_port)
            connect_hop!(bufio, hop, next_host, next_port, hop_index: index + 1)
          end

          socket
        rescue StandardError
          socket&.close
          raise
        end
        private_class_method :open_tunnel

        def self.dial_first_hop(first_hop, open_timeout)
          Socket.tcp(first_hop.proxy_uri.host, first_hop.proxy_uri.port, connect_timeout: open_timeout)
        rescue StandardError => e
          raise ProxyError.new(hop_index: 1, host: first_hop.proxy_uri, detail: "#{e.class}: #{e.message}")
        end
        private_class_method :dial_first_hop

        def self.next_hop_target(chain, index, target_host, target_port)
          return [target_host, target_port] unless index + 1 < chain.length

          next_hop = chain[index + 1]
          [next_hop.proxy_uri.host, next_hop.proxy_uri.port]
        end
        private_class_method :next_hop_target

        def self.connect_hop!(bufio, hop, next_host, next_port, hop_index:)
          bufio.write(connect_request(hop, next_host, next_port))
          response = Net::HTTPResponse.read_new(bufio)
          status = response.code.to_i
          return if status == 200

          raise ProxyError.new(hop_index: hop_index, host: hop.proxy_uri, status: status)
        rescue IOError, SystemCallError, Net::HTTPBadResponse => e
          # EOFError < IOError, so it's already covered above.
          raise ProxyError.new(hop_index: hop_index, host: hop.proxy_uri, detail: "#{e.class}: #{e.message}")
        end
        private_class_method :connect_hop!

        def self.connect_request(hop, next_host, next_port)
          buf = "CONNECT #{next_host}:#{next_port} HTTP/1.1\r\nHost: #{next_host}:#{next_port}\r\n"
          hop.proxy_headers.each { |key, value| buf << "#{key}: #{value}\r\n" }
          if hop.proxy_uri.user
            credential = "#{decoded(hop.proxy_uri.user)}:#{decoded(hop.proxy_uri.password)}"
            buf << "Proxy-Authorization: Basic #{[credential].pack('m0')}\r\n"
          end
          buf << "\r\n"
          buf
        end
        private_class_method :connect_request

        def self.start_tls(socket, hostname, hop)
          ctx = OpenSSL::SSL::SSLContext.new
          ctx.set_params(verify_mode: OpenSSL::SSL::VERIFY_PEER)
          ctx.cert_store = build_cert_store(hop.ca_file) if hop.ca_file
          ssl_socket = OpenSSL::SSL::SSLSocket.new(socket, ctx)
          ssl_socket.sync_close = true
          ssl_socket.hostname = hostname if ssl_socket.respond_to?(:hostname=)
          ssl_socket.connect
          ssl_socket
        end
        private_class_method :start_tls

        # Phase 3 of docs/plans/proxy-support.md: applies the current
        # fiber's Support::PassthroughContext (an inbound request's
        # allowlisted headers, plus how to build the outbound
        # Forwarded/X-Forwarded-For chain) to every request this block
        # makes, regardless of which route/hop kind resolved. `.wrap`
        # returns `http` itself, untouched, whenever there is no
        # PassthroughContext in flight (the overwhelmingly common case —
        # most outbound calls happen outside of any inbound request), so
        # this never adds overhead to a call that isn't serving one.
        class PassthroughHttp
          def self.wrap(http) = Support::PassthroughContext.current ? new(http) : http

          def initialize(http)
            @http = http
          end

          def request(req)
            apply!(req)
            @http.request(req)
          end

          def get(path, headers = nil)
            req = Net::HTTP::Get.new(path, headers || {})
            apply!(req)
            @http.request(req)
          end

          def post(path, data, headers = nil)
            req = Net::HTTP::Post.new(path, headers || {})
            req.body = data
            apply!(req)
            @http.request(req)
          end

          private

          def apply!(req)
            Support::PassthroughContext.headers.each { |name, value| req[name] = value }
            apply_forwarded!(req)
          end

          # "drop" (the default, and whenever no chain_entry was resolved)
          # never touches the outbound Forwarded/X-Forwarded-For headers at
          # all; "replace" overwrites whatever the caller's own request
          # already carried; "append" adds this hop onto the end of it.
          def apply_forwarded!(req)
            entry = Support::PassthroughContext.chain_entry
            mode = Support::PassthroughContext.forwarded_mode
            return if entry.nil? || mode == "drop"

            req["X-Forwarded-For"] = chain_value(req["X-Forwarded-For"], entry, mode)
            req["Forwarded"] = chain_value(req["Forwarded"], "for=#{entry}", mode, sep: ", ")
          end

          def chain_value(existing, entry, mode, sep: ", ")
            return entry if mode == "replace" || existing.to_s.empty?

            "#{existing}#{sep}#{entry}"
          end
        end

        # A Net::HTTP-alike bound to an already-established (and, for an
        # https:// target, already TLS-wrapped) socket that reached the
        # target through a hand-rolled tunnel Net::HTTP itself has no way
        # to build. Reuses Net::HTTPGenericRequest#exec and
        # Net::HTTPResponse.read_new/#reading_body — the exact wire-format
        # code Net::HTTP's own #transport_request drives — rather than
        # reimplementing HTTP/1.1 framing by hand.
        class TunnelledHttp
          def initialize(bufio, host:, port:)
            @bufio = bufio
            @host = host
            @port = port
          end

          def request(req)
            req["host"] ||= "#{@host}:#{@port}"
            req.exec(@bufio, "1.1", req.path)
            response = Net::HTTPResponse.read_new(@bufio)
            # reading_body requires a block (it yields); the body itself is read via #body, below.
            response.reading_body(@bufio, req.response_body_permitted?) {} # rubocop:disable Lint/EmptyBlock
            response
          end

          def get(path, headers = nil)
            request(Net::HTTP::Get.new(path, headers || {}))
          end

          def post(path, data, headers = nil)
            req = Net::HTTP::Post.new(path, headers || {})
            req.body = data
            request(req)
          end
        end

        # Wraps a real Net::HTTP already connected to the gateway's own
        # host/port. Rewrites every outgoing request to carry the real
        # target the way the profile says to (target_header, target_param,
        # or the `{base}/{host}{path}` prefix fallback) — the caller's own
        # request is built exactly as it would be against a direct
        # connection (it doesn't know it's talking to a gateway at all),
        # so the rewrite has to happen here, not at the caller.
        class GatewayHttp
          def initialize(http, profile:, target_uri:, gateway_uri:)
            @http = http
            @profile = profile
            @target_uri = target_uri
            @gateway_uri = gateway_uri
          end

          def request(req)
            @http.request(rewrite(req))
          end

          def get(_path, headers = nil)
            request(Net::HTTP::Get.new(@target_uri.request_uri, headers || {}))
          end

          def post(_path, data, headers = nil)
            req = Net::HTTP::Post.new(@target_uri.request_uri, headers || {})
            req.body = data
            request(req)
          end

          private

          def rewrite(req)
            new_req = req.class.new(gateway_path)
            req.each_header { |key, value| new_req[key] = value }
            @profile.proxy_headers.each { |key, value| new_req[key] = value }
            new_req[@profile.target_header] = @target_uri.to_s if @profile.target_header
            new_req.body = req.body if req.body
            new_req.body_stream = req.body_stream if req.body_stream
            new_req
          end

          def gateway_path
            if @profile.target_param
              pairs = URI.decode_www_form(@gateway_uri.query.to_s) << [@profile.target_param, @target_uri.to_s]
              "#{@gateway_uri.path}?#{URI.encode_www_form(pairs)}"
            elsif @profile.target_header
              @gateway_uri.request_uri
            else
              "#{@gateway_uri.path.chomp('/')}/#{@target_uri.host}#{@target_uri.request_uri}"
            end
          end
        end
      end
    end
  end
end
