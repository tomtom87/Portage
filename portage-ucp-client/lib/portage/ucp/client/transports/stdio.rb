module Portage
  module Ucp
    module Client
      module Transports
        # Connects to a UCP/MCP server over stdio — a subprocess speaking
        # JSON-RPC on stdin/stdout — via the official `mcp` gem's client half
        # (MCP::Client + MCP::Client::Stdio). Performs the `initialize`
        # handshake eagerly so a caller's first real call doesn't pay for it.
        class Stdio
          def initialize(command:, args: [], env: nil)
            @client = ::MCP::Client.new(transport: ::MCP::Client::Stdio.new(command: command, args: args, env: env))
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
