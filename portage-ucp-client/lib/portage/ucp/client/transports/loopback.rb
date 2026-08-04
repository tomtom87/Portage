module Portage
  module Ucp
    module Client
      module Transports
        # Wraps a Portage::Ucp::Mcp::Server built directly from an Adapter —
        # no subprocess, no socket. This still runs the exact request a real
        # server would handle over stdio/HTTP (authenticator, rate limiter,
        # Dispatcher, WireEnvelope — see Portage::Ucp::Mcp::Server.build), it
        # just skips the wire hop. This is what makes the
        # merchant-buys-from-their-own-store case, and specs/examples that
        # want a full buy cycle, possible without two processes.
        class Loopback
          def initialize(adapter:, **server_opts)
            @server = Portage::Ucp::Mcp::Server.build(adapter: adapter, **server_opts)
            @next_id = 0
          end

          def call_tool(name:, arguments:)
            @next_id += 1
            response = @server.handle(
              { jsonrpc: "2.0", id: @next_id, method: "tools/call", params: { name: name, arguments: arguments } }
            )
            ToolResult.extract(response, symbol_keys: true)
          end
        end
      end
    end
  end
end
