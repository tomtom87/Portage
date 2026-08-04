module Portage
  module Ucp
    module Client
      module Transports
        # Connects to a UCP/MCP server over Streamable HTTP via the official
        # `mcp` gem's client half (MCP::Client + MCP::Client::HTTP). Performs
        # the `initialize` handshake eagerly so a caller's first real call
        # doesn't pay for it.
        class Http
          def initialize(url:, headers: {})
            @client = ::MCP::Client.new(transport: ::MCP::Client::HTTP.new(url: url, headers: headers))
            @client.connect
          end

          def call_tool(name:, arguments:)
            response = @client.call_tool(name: name, arguments: arguments)
            ToolResult.extract(response, symbol_keys: false)
          end
        end
      end
    end
  end
end
