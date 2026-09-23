require "json"
require "rack"

module Portage
  module Ucp
    module WebMcp
      module Rack
        # POST target for the page registrar's tool calls: one stateless
        # JSON-RPC request in, one response out, handed to the ToolCatalog's
        # Portage::Ucp::Mcp::Server — the same Authenticator, RateLimiter,
        # Dispatcher and WireEnvelope stdio and Streamable HTTP go through.
        #
        # Browser-facing, so it is stricter than a plain MCP endpoint:
        #   - JSON bodies only, so a cross-site `<form>` can't reach it
        #     without a CORS preflight;
        #   - an `Origin` header matching `allowed_origins` (default: this
        #     request's own origin) is required, since the page's cookies ride
        #     along and an Authenticator reading them would otherwise be
        #     open to cross-site request forgery;
        #   - only tools/call and tools/list, and only for actions the
        #     catalog exposes.
        #
        # The Authenticator's server_context carries `transport: "webmcp"`,
        # `request:` (the Rack::Request, for session cookies or a CSRF
        # header) and `origin:`, plus the `_meta` the page sent.
        class CallEndpoint
          METHODS = %w[tools/call tools/list].freeze
          JSON_HEADERS = { "content-type" => "application/json", "cache-control" => "no-store" }.freeze

          # @param allowed_origins [Array<String>, nil] exact origins
          #   ("https://shop.example"); nil allows only the endpoint's own.
          # @param require_origin [Boolean] reject requests with no `Origin`
          #   header. Every browser sends one on a POST fetch, so leave this
          #   on unless a non-browser caller must reach this endpoint (point
          #   it at the regular MCP endpoint instead).
          def initialize(catalog:, allowed_origins: nil, require_origin: true)
            @catalog = catalog
            @allowed_origins = allowed_origins&.map { |origin| origin.to_s.chomp("/") }
            @require_origin = require_origin
          end

          def call(env)
            request = ::Rack::Request.new(env)
            return preflight(request) if request.options?
            return http_error(405, "method not allowed", "allow" => "POST, OPTIONS") unless request.post?
            return http_error(403, "origin not allowed") unless origin_allowed?(request)
            return http_error(415, "content-type must be application/json") unless json?(request)

            handle(request)
          end

          private

          def handle(request)
            payload = parse(request)
            return respond(request, rpc_error(nil, -32_700, "Parse error")) unless payload.is_a?(Hash)

            respond(request, dispatch(request, payload))
          end

          def dispatch(request, payload)
            id = payload[:id]
            method = payload[:method].to_s
            return rpc_error(id, -32_601, "Method not found: #{method}") unless METHODS.include?(method)
            return tools_list(id) if method == "tools/list"

            name = payload.dig(:params, :name).to_s
            return rpc_error(id, -32_602, "Tool not exposed over WebMCP: #{name}") unless @catalog.exposes?(name)

            server_for(request).handle(payload)
          end

          def parse(request)
            JSON.parse(request.body.read, symbolize_names: true)
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
          def server_for(request)
            @catalog.server.dup.tap do |server|
              server.server_context = { transport: "webmcp", request: request,
                                        origin: request.get_header("HTTP_ORIGIN") }
            end
          end

          def origin_allowed?(request)
            origin = request.get_header("HTTP_ORIGIN")
            return !@require_origin if origin.nil? || origin.empty?

            allowed_origins(request).include?(origin.chomp("/"))
          end

          def allowed_origins(request)
            @allowed_origins || [request.base_url]
          end

          def json?(request)
            request.media_type == "application/json"
          end

          def preflight(request)
            return http_error(403, "origin not allowed") unless origin_allowed?(request)

            headers = cors_headers(request).merge(
              "access-control-allow-methods" => "POST, OPTIONS",
              "access-control-allow-headers" => request.get_header("HTTP_ACCESS_CONTROL_REQUEST_HEADERS") ||
                                                "content-type, accept",
              "access-control-max-age" => "600"
            )
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

          def http_error(status, message, extra_headers = {})
            [status, JSON_HEADERS.merge(extra_headers), [JSON.generate(error: message)]]
          end
        end
      end
    end
  end
end
