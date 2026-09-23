require_relative "../errors"
require_relative "ucp_wire_shape"

module Portage
  module Ucp
    module Client
      module Transports
        # Connects to a UCP/MCP server over Streamable HTTP via the official
        # `mcp` gem's client half (MCP::Client + MCP::Client::HTTP). Performs
        # the `initialize` handshake eagerly so a caller's first real call
        # doesn't pay for it.
        #
        # Session's public API (query:/limit:, cart_id:/checkout_id:/
        # order_id:, line_items: [{product_id:, quantity:}], ...) stays flat
        # — it's shared with Loopback, which hands arguments straight to this
        # gem's own Dispatcher/adapters, and those speak that flat shape by
        # design (see portage-ucp/lib/portage/ucp/mcp/server.rb). Real UCP
        # servers don't: confirmed live against Shopify's 2026-08-25 rollout,
        # every tool nests its arguments under a capability key
        # (catalog:/cart:/checkout:) and requires a `meta.ucp-agent.profile`
        # URL the server itself fetches to verify the caller's identity. This
        # transport is the one place that reshapes Session's flat arguments
        # into that real wire format before the request goes out — Loopback
        # and Stdio are untouched.
        class Http
          include UcpWireShape

          def initialize(url:, headers: {})
            @client = ::MCP::Client.new(transport: ::MCP::Client::HTTP.new(url: url, headers: headers))
            @client.connect
          end

          # `meta` here is a *property of the tool's own `arguments` object*
          # (confirmed live against Shopify's schema — every tool's
          # input_schema lists "meta" as a top-level sibling of
          # "catalog"/"cart"/"checkout"), not the MCP protocol's `_meta`
          # envelope field. `MCP::Client#call_tool`'s own `meta:` kwarg sends
          # the latter, so it's unused here — the caller-supplied meta gets
          # folded into `arguments["meta"]` instead.
          def call_tool(name:, arguments:, meta: nil)
            idempotency_key = arguments[:idempotency_key] || arguments["idempotency_key"]
            wire = wire_arguments(name, arguments)
            wire["meta"] = wire_meta(meta, idempotency_key)
            response = @client.call_tool(name: name, arguments: wire)
            ToolResult.extract(response, symbol_keys: false)
          rescue ServerError, MCP::Client::RequestHandlerError => e
            raise permission_error(e) if name == "complete_checkout" && permission_refusal?(e.message)

            raise
          end

          private

          # `idempotency_key` arrives via `arguments` — Session#call folds it
          # in there for every mutating action — not via `meta`, so it has to
          # be threaded through here rather than read off `meta` directly.
          def wire_meta(meta, idempotency_key)
            profile = meta && (meta[:agent_profile] || meta["agent_profile"])
            unless profile
              raise MissingAgentProfileError,
                    "meta: { agent_profile: <url> } is required for HTTP calls — real UCP servers fetch " \
                    "and verify this URL to identify the calling agent"
            end

            wire = { "ucp-agent" => { "profile" => profile } }
            wire["idempotency-key"] = idempotency_key if idempotency_key
            wire
          end
        end
      end
    end
  end
end
