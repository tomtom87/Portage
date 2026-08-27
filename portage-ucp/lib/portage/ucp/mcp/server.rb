require "mcp"
require "securerandom"

module Portage
  module Ucp
    module Mcp
      # Builds an MCP::Server (from the `mcp` gem) whose tools are generated
      # from the CapabilityRegistry's advertised actions for a given adapter,
      # so tools/list and tools/call stay in sync with the Dispatcher/registry
      # instead of being hand-duplicated per capability.
      class Server
        # Collaborators shared by every generated tool, bundled so build_tool
        # doesn't need one keyword argument per collaborator.
        Context = Struct.new(:dispatcher, :authenticator, :rate_limiter, :logger, keyword_init: true)

        def self.build(adapter:, registry: Portage::Ucp.configuration.registry,
                       authenticator: Portage::Ucp.configuration.authenticator,
                       rate_limiter: Portage::Ucp.configuration.rate_limiter,
                       logger: Portage::Ucp.configuration.logger, **server_opts)
          context = Context.new(
            dispatcher: Portage::Ucp::Dispatcher.new(adapter: adapter, registry: registry, logger: logger),
            authenticator: authenticator, rate_limiter: rate_limiter, logger: logger
          )
          tools = registry.advertised(adapter).flat_map do |capability|
            capability.actions.map do |action_name, method_name|
              build_tool(adapter: adapter, capability: capability, action_name: action_name,
                         method_name: method_name, context: context)
            end
          end

          ::MCP::Server.new(name: "portage-ucp", tools: tools, **server_opts)
        end

        def self.build_tool(adapter:, capability:, action_name:, method_name:, context:)
          keyword_params = adapter.method(method_name).parameters.select { |type, _| %i[key keyreq].include?(type) }
          required = keyword_params.select { |type, _| type == :keyreq }.map { |_, name| name.to_s }
          properties = keyword_params.to_h { |_, name| [name.to_s, {}] }
          mutating = keyword_params.any? { |_, name| name == :idempotency_key }

          ::MCP::Tool.define(
            name: action_name,
            description: "#{capability.name}##{action_name}",
            input_schema: { type: "object", properties: properties, required: required }
          ) do |**kwargs|
            Portage::Ucp::Mcp::Server.call_tool(context: context, capability: capability, action_name: action_name,
                                                mutating: mutating, kwargs: kwargs)
          end
        end

        def self.call_tool(context:, capability:, action_name:, mutating:, kwargs:)
          server_context = kwargs.delete(:server_context)
          correlation_id = correlation_id_for(server_context)
          Portage::Ucp::Observability.log(context.logger, "tool_call_received", capability: capability.name,
                                                                                action: action_name,
                                                                                correlation_id: correlation_id)

          rejection = authorize(context.authenticator, server_context, mutating: mutating) ||
                      rate_limit(context.rate_limiter, server_context, capability.name, mutating: mutating)
          return rejection if rejection

          Portage::Ucp::Observability.log(context.logger, "tool_called", capability: capability.name,
                                                                         action: action_name, arguments: kwargs,
                                                                         correlation_id: correlation_id)

          result = context.dispatcher.call(capability: capability.name, action: action_name, arguments: kwargs,
                                           correlation_id: correlation_id)
          ::MCP::Tool::Response.new(result[:content], structured_content: result[:structuredContent])
        end

        # Per-request correlation only (§23): `Context` above is built once per
        # process in `.build`, and mcp 0.25.0's Streamable HTTP transport is
        # explicitly stateful/multi-session, so memoizing an id there would
        # stamp every session in the process with the same value. Prefers the
        # inbound W3C `traceparent` the MCP spec passes through `_meta`
        # untouched (SEP-414, see `MCP::TraceContext`) so a caller that already
        # traces its own calls gets one trace across both sides; generates a
        # fallback only when absent.
        #
        # `traceparent` is unauthenticated input — reachable before
        # `authorize`/`rate_limit` run, same as the pre-auth event this
        # correlation id feeds. Validated against W3C Trace Context's own
        # format before use, which is spec-correct behavior (a malformed
        # traceparent MUST be treated as absent, restarting the trace), and
        # incidentally closes off unbounded-length log writes and non-String
        # values reaching Dispatcher/CheckoutState as a "correlation_id".
        TRACEPARENT_FORMAT = /\A[0-9a-f]{2}-[0-9a-f]{32}-[0-9a-f]{16}-[0-9a-f]{2}\z/

        def self.correlation_id_for(server_context)
          meta = server_context[:_meta] if server_context.respond_to?(:[])
          traceparent = meta && (meta[:traceparent] || meta["traceparent"])
          traceparent.is_a?(String) && TRACEPARENT_FORMAT.match?(traceparent) ? traceparent : SecureRandom.uuid
        end

        def self.authorize(authenticator, server_context, mutating:)
          return unless mutating

          authenticator.call(server_context)
          nil
        rescue Portage::Ucp::AuthenticationError => e
          ::MCP::Tool::Response.new([{ type: "text", text: e.message }], error: true)
        end

        # @param key [Object] whatever the consumer's RateLimiter derives an
        #   identity from — the gem hands over the raw MCP server_context
        #   rather than inventing its own per-session/per-key extraction (§9).
        def self.rate_limit(rate_limiter, key, capability_name, mutating:)
          return unless mutating

          rate_limiter.check!(key, capability_name)
          nil
        rescue Portage::Ucp::RateLimitExceededError => e
          ::MCP::Tool::Response.new([{ type: "text", text: e.message }], error: true)
        end
      end
    end
  end
end
