require "json"
require "rack"
require_relative "request_limits"

module Portage
  module Ucp
    module WebMcp
      module Rack
        # POST target for the page registrar's tool calls: one stateless
        # JSON-RPC request in, one response out, handed to the ToolCatalog's
        # Portage::Ucp::Mcp::Server — the same Authenticator, RateLimiter,
        # Dispatcher and WireEnvelope stdio and Streamable HTTP go through.
        #
        # Browser-facing, so it is stricter than a plain MCP endpoint: JSON
        # bodies only (a cross-site `<form>` can't reach it without a CORS
        # preflight); an `Origin` matching `allowed_origins` (default: this
        # request's own origin) is required, since the page's cookies ride
        # along and an Authenticator reading them would otherwise be open to
        # CSRF; only tools/call and tools/list, and only for actions the
        # catalog exposes; and both the body size and the call itself are
        # bounded (`max_body_bytes:`, `call_timeout:`).
        #
        # The Authenticator's server_context carries `transport: "webmcp"`,
        # `request:` (the Rack::Request, for session cookies or a CSRF
        # header) and `origin:`, plus the `_meta` the page sent.
        class CallEndpoint
          METHODS = %w[tools/call tools/list].freeze
          JSON_HEADERS = { "content-type" => "application/json", "cache-control" => "no-store" }.freeze

          # One JSON-RPC envelope shape for every failure path: a request that
          # never reached `Mcp::Server` (bad origin, bad params, an oversized
          # body) and one that ran there and timed out both answer this way.
          PARSE_ERROR = -32_700
          INVALID_REQUEST = -32_600
          METHOD_NOT_FOUND = -32_601
          INVALID_PARAMS = -32_602
          SERVER_ERROR = -32_000

          # @param allowed_origins [Array<String>, nil] exact origins
          #   ("https://shop.example"); nil allows only the endpoint's own.
          #   Checked against the real `Origin` header always — see
          #   #origin_allowed? and `forwarded_host_allowed:` below.
          # @param require_origin [Boolean] reject requests with no `Origin`
          #   header (every browser sends one on a POST fetch); turn off only
          #   for a non-browser caller (point it at the MCP endpoint instead).
          # @param max_body_bytes [Integer] see RequestLimits.
          # @param call_timeout [Numeric, nil] see RequestLimits.
          # @param trusted_proxies [Array<String>] CIDRs of the consumer's
          #   own reverse proxy/load balancer (docs/plans/proxy-support.md
          #   Phase 3) — a consumer behind one sets this, e.g.
          #   `CallEndpoint.new(catalog: catalog, trusted_proxies:
          #   ["10.0.0.0/8"])`. Fail-closed: empty (the default) means every
          #   `X-Forwarded-*`/`Forwarded` header is ignored, unchanged from
          #   before this option existed. See Rack::ForwardedRequest.
          # @param forwarded_host_allowed [Array<String>] host[:port] values
          #   `X-Forwarded-Host`/`Forwarded;host=` is allowed to replace
          #   "the endpoint's own origin" with (what #origin_allowed? treats
          #   as same-origin) — only from a trusted peer, and only ever
          #   *replacing* what "own origin" means, never adding to
          #   `allowed_origins` itself. A spoofed X-Forwarded-Host that
          #   isn't on this list (or didn't come from a trusted peer) has no
          #   effect at all.
          # @param passthrough_headers [Array<String>] inbound header names
          #   allowlisted to reach outbound calls a tool makes while this
          #   request is being served (Support::Connection, via the
          #   fiber-local Support::PassthroughContext) — from a trusted peer
          #   only. Never a protected header (raises at construction time).
          # @param passthrough_forwarded ["append", "replace", "drop"] see
          #   Support::PassthroughContext.
          def initialize(catalog:, allowed_origins: nil, require_origin: true, trusted_proxies: [],
                         forwarded_host_allowed: [], passthrough_headers: [], passthrough_forwarded: "drop",
                         **limit_opts)
            @catalog = catalog
            @allowed_origins = allowed_origins&.map { |origin| origin.to_s.chomp("/") }
            @require_origin = require_origin
            @limits = RequestLimits.new(**limit_opts)
            @trusted_proxies = trusted_proxies
            @forwarded_host_allowed = forwarded_host_allowed
            @passthrough_headers = passthrough_headers
            @passthrough_forwarded = passthrough_forwarded
            Portage::Ucp::Rack::ForwardedRequest.validate_passthrough!(@passthrough_headers)
          end

          def call(env)
            request = ::Rack::Request.new(env)
            forwarded = Portage::Ucp::Rack::ForwardedRequest.new(request, trusted_proxies: @trusted_proxies)
            return preflight(request, forwarded) if request.options?
            return http_error(request, 405, INVALID_REQUEST, "method not allowed", "allow" => "POST, OPTIONS") \
              unless request.post?
            return http_error(request, 403, INVALID_REQUEST, "origin not allowed") \
              unless origin_allowed?(request, forwarded)
            return http_error(request, 415, INVALID_REQUEST, "content-type must be application/json") \
              unless request.media_type == "application/json"
            return http_error(request, 413, SERVER_ERROR, "request body too large") \
              if @limits.body_too_large?(request)

            handle(request, forwarded)
          end

          private

          def handle(request, forwarded)
            payload = parse(request)
            return http_error(request, 413, SERVER_ERROR, "body too large") if payload == RequestLimits::TOO_LARGE
            return respond(request, rpc_error(nil, PARSE_ERROR, "Parse error")) unless payload.is_a?(Hash)

            respond(request, dispatch(request, forwarded, payload))
          end

          def dispatch(request, forwarded, payload)
            id = payload[:id]
            method = payload[:method]
            return rpc_error(id, METHOD_NOT_FOUND, "Method not found: #{method}") \
              unless method.is_a?(String) && METHODS.include?(method)
            return tools_list(id) if method == "tools/list"

            name = tool_name(payload[:params])
            return rpc_error(id, INVALID_PARAMS, "Invalid params") if name.nil?
            return rpc_error(id, INVALID_PARAMS, "Tool not exposed over WebMCP: #{name}") \
              unless @catalog.exposes?(name)

            result = with_passthrough(forwarded) do
              @limits.call_with_timeout { server_for(request, forwarded).handle(payload) }
            end
            result == RequestLimits::TIMED_OUT ? rpc_error(id, SERVER_ERROR, "tool call timed out") : result
          end

          # Only from a trusted peer, and only when there's actually
          # something configured to pass through — an untrusted peer's
          # request runs with no PassthroughContext at all, same as if
          # trusted_proxies had never been set.
          def with_passthrough(forwarded, &)
            return yield unless forwarded.peer_trusted? && @passthrough_headers.any?

            headers = forwarded.passthrough_headers(@passthrough_headers)
            Portage::Ucp::Support::PassthroughContext.with(headers: headers, forwarded: @passthrough_forwarded,
                                                           chain_entry: forwarded.client_ip, &)
          end

          # `params` on a well-formed `tools/call` is a Hash (or absent); a
          # String/Integer/boolean there used to reach `payload.dig(:params,
          # :name)`, which raises TypeError once `:params` isn't itself
          # dig-able. `nil` here means "invalid", not "no name" — the caller
          # can't tell those apart from an empty string.
          def tool_name(params)
            return "" if params.nil?
            return nil unless params.is_a?(Hash)

            params[:name].to_s
          end

          def parse(request)
            raw = @limits.read_body(request)
            return RequestLimits::TOO_LARGE if raw == RequestLimits::TOO_LARGE

            JSON.parse(raw, symbolize_names: true)
          rescue JSON::ParserError
            nil
          end

          # The catalog's own decorated descriptors, not the underlying
          # server's list — so this can't advertise a tool calls would refuse.
          def tools_list(id)
            tools = @catalog.tools.map do |tool|
              { name: tool["action"], description: tool["description"], inputSchema: tool["inputSchema"],
                annotations: tool["annotations"] }
            end
            { jsonrpc: "2.0", id: id, result: { tools: tools } }
          end

          # MCP::Server holds one server_context for its lifetime; a shallow
          # copy per request gives each call its own without rebuilding the
          # tool set or sharing state across concurrent requests.
          #
          # `client_ip` is the ForwardedRequest-resolved one (right-most
          # untrusted hop from a trusted peer, the plain socket peer
          # otherwise) — this is how a host app's RateLimiter/Authenticator
          # reach the real client rather than the reverse proxy's own
          # address (docs/plans/proxy-support.md Phase 3).
          def server_for(request, forwarded)
            @catalog.server.dup.tap do |server|
              server.server_context = { transport: "webmcp", request: request,
                                        origin: request.get_header("HTTP_ORIGIN"),
                                        client_ip: forwarded.client_ip }
            end
          end

          # `Origin` itself is always the real header — never replaced or
          # widened by anything forwarded. Only what counts as "our own
          # origin" (the right-hand side of the comparison, for the
          # `allowed_origins.nil?` default case) can move, and only to a
          # host explicitly listed in `forwarded_host_allowed`, from a
          # trusted peer. A spoofed X-Forwarded-Host that fails either
          # check leaves this exactly as if it were never sent.
          def origin_allowed?(request, forwarded)
            origin = request.get_header("HTTP_ORIGIN")
            return !@require_origin if origin.nil? || origin.empty?

            own_origin = forwarded.own_origin(forwarded_host_allowed: @forwarded_host_allowed)
            (@allowed_origins || [own_origin]).include?(origin.chomp("/"))
          end

          def preflight(request, forwarded)
            return http_error(request, 403, INVALID_REQUEST, "origin not allowed") \
              unless origin_allowed?(request, forwarded)

            allow_headers = request.get_header("HTTP_ACCESS_CONTROL_REQUEST_HEADERS") || "content-type, accept"
            headers = cors_headers(request).merge("access-control-allow-methods" => "POST, OPTIONS",
                                                  "access-control-allow-headers" => allow_headers,
                                                  "access-control-max-age" => "600")
            [204, headers, []]
          end

          # Only for an allowed origin other than our own — a same-origin page
          # needs no CORS headers at all.
          def cors_headers(request)
            origin = request.get_header("HTTP_ORIGIN")
            return {} if origin.nil? || origin == request.base_url

            { "access-control-allow-origin" => origin, "access-control-allow-credentials" => "true",
              "vary" => "Origin" }
          end

          def respond(request, body)
            return [202, cors_headers(request), []] if body.nil?

            [200, JSON_HEADERS.merge(cors_headers(request)), [JSON.generate(body)]]
          end

          def rpc_error(id, code, message)
            { jsonrpc: "2.0", id: id, error: { code: code, message: message } }
          end

          # Every rejection — CORS/method/content-type/size checks that never
          # reach `dispatch`, same as a JSON-RPC error `dispatch` itself
          # returns — answers with the same envelope shape, so a caller
          # doesn't need to branch on HTTP status to read the error.
          def http_error(request, status, code, message, extra_headers = {})
            headers = JSON_HEADERS.merge(cors_headers(request)).merge(extra_headers)
            [status, headers, [JSON.generate(rpc_error(nil, code, message))]]
          end
        end
      end
    end
  end
end
