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

          # `context`/`cart_id`/`handler_id`/`credential_type` are real-UCP
          # wire concerns Session offers for Transports::Http to nest into a
          # request body. This transport hands arguments straight to this
          # gem's own Dispatcher, which splats them into an Adapter method
          # signature that has no such keywords, so passing them on would be
          # an ArgumentError on every call. Dropped here rather than branched
          # on in Session, so each transport keeps owning which arguments it
          # understands.
          REMOTE_WIRE_ARGUMENTS = %i[context cart_id handler_id credential_type].freeze

          def call_tool(name:, arguments:, meta: nil)
            response = @client.call_tool(name: name, arguments: arguments.except(*REMOTE_WIRE_ARGUMENTS), meta: meta)
            ToolResult.extract(response, symbol_keys: false)
          end
        end
      end
    end
  end
end
