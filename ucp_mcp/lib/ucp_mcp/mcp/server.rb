require "mcp"

module UcpMcp
  module Mcp
    # Builds an MCP::Server (from the `mcp` gem) whose tools are generated
    # from the CapabilityRegistry's advertised actions for a given adapter,
    # so tools/list and tools/call stay in sync with the Dispatcher/registry
    # instead of being hand-duplicated per capability.
    class Server
      def self.build(adapter:, registry: UcpMcp::CapabilityRegistry.default,
                     authenticator: UcpMcp::UnconfiguredAuthenticator.new, **server_opts)
        dispatcher = UcpMcp::Dispatcher.new(adapter: adapter, registry: registry)
        tools = registry.advertised(adapter).flat_map do |capability|
          capability.actions.map do |action_name, method_name|
            build_tool(adapter: adapter, dispatcher: dispatcher, capability: capability,
                       action_name: action_name, method_name: method_name, authenticator: authenticator)
          end
        end

        ::MCP::Server.new(name: "ucp_mcp", tools: tools, **server_opts)
      end

      def self.build_tool(adapter:, dispatcher:, capability:, action_name:, method_name:, authenticator:)
        keyword_params = adapter.method(method_name).parameters.select { |type, _| %i[key keyreq].include?(type) }
        required = keyword_params.select { |type, _| type == :keyreq }.map { |_, name| name.to_s }
        properties = keyword_params.to_h { |_, name| [name.to_s, {}] }
        mutating = keyword_params.any? { |_, name| name == :idempotency_key }

        ::MCP::Tool.define(
          name: action_name,
          description: "#{capability.name}##{action_name}",
          input_schema: { type: "object", properties: properties, required: required }
        ) do |**kwargs|
          server_context = kwargs.delete(:server_context)
          rejection = UcpMcp::Mcp::Server.authorize(authenticator, server_context, mutating: mutating)
          next rejection if rejection

          result = dispatcher.call(capability: capability.name, action: action_name, arguments: kwargs)
          ::MCP::Tool::Response.new(result[:content], structured_content: result[:structuredContent])
        end
      end

      def self.authorize(authenticator, server_context, mutating:)
        return unless mutating

        authenticator.call(server_context)
        nil
      rescue UcpMcp::AuthenticationError => e
        ::MCP::Tool::Response.new([{ type: "text", text: e.message }], error: true)
      end
    end
  end
end
