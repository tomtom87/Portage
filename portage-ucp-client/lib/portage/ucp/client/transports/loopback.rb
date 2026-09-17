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

          def call_tool(name:, arguments:, meta: nil)
            @next_id += 1
            response = @server.handle(
              { jsonrpc: "2.0", id: @next_id, method: "tools/call",
                params: { name: name, arguments: arguments, **(meta ? { _meta: wire_meta(meta) } : {}) } }
            )
            ToolResult.extract(response, symbol_keys: true)
          end

          private

          # Session's transport-agnostic `meta: { agent_profile: <url> }`
          # convention (the one `Buy#agent_meta` actually passes, regardless
          # of which transport `session` turns out to be) has to reach
          # `Mcp::Server.agent_profile_for`, which only ever looks at
          # `_meta["ucp-agent.profile"]`/`_meta[:"ucp-agent.profile"]` — a
          # different key. Without this, an own-store loopback buy silently
          # dropped its agent_profile (no error, just a blank field in
          # tool_call_received/tool_called events) while the real-store HTTP
          # transport picked the same `agent_profile:` key up correctly.
          # Merges rather than replaces so a caller already using the
          # server's own key (as this gem's specs do) is untouched.
          def wire_meta(meta)
            profile = meta[:agent_profile] || meta["agent_profile"]
            profile ? meta.merge("ucp-agent.profile" => profile) : meta
          end
        end
      end
    end
  end
end
