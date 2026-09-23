require_relative "tool_schemas"

module Portage
  module Ucp
    module WebMcp
      # The merchant-side source of truth for what a page registers over
      # WebMCP. Builds the same Portage::Ucp::Mcp::Server stdio/Streamable
      # HTTP use (so tools/list stays generated from the CapabilityRegistry and
      # the Adapter's own method signatures — nothing hand-duplicated here),
      # then decorates each tool with what a browser-native agent needs and
      # the MCP server's generated schema doesn't carry: a readable
      # description, typed parameter schemas, and WebMCP annotations.
      #
      # Rack::CallEndpoint enforces the same filter server-side, so a tool
      # left out of the page can't be reached by POSTing its name anyway.
      class ToolCatalog
        # Standard dev.ucp.shopping.* capabilities only, identity linking
        # excluded: every tool outside that set (identity, saved payment
        # methods, saved addresses, shopper-data deletion, payment
        # enrollment) takes an OAuth token or manages stored credentials,
        # which a page script has no business relaying on an agent's behalf.
        # Pass `capabilities:` to widen it deliberately.
        DEFAULT_CAPABILITIES = lambda do |capability_name|
          capability_name.start_with?("dev.ucp.shopping.") && capability_name != "dev.ucp.shopping.identity"
        end

        # Left out unless asked for with `except: []`. Over any server
        # transport, complete_checkout runs Dispatcher's payment Confirmer,
        # which defaults to Confirmer::Terminal — a prompt on the *server's*
        # stdin — and Mcp::Server.build has no seam to swap it. Behind a web
        # page that holds the request until the prompt times out and denies.
        # A browser-native agent has the shopper right there anyway: it
        # builds the checkout, the shopper pays in the store's own checkout
        # (the checkout's `links`/`continue_url`).
        DEFAULT_EXCEPT = %w[complete_checkout].freeze

        # WebMCP `consequentialHint`: the effect is hard or impossible to take
        # back (money moves, an order changes). Other mutating tools still get
        # `readOnlyHint: false`.
        CONSEQUENTIAL_ACTIONS = %w[complete_checkout cancel_order refund_order request_return reorder].freeze

        attr_reader :server, :tools, :prefix

        # @param prefix [String, nil] prepended to every registered tool name
        #   (e.g. "acme." for "acme.search_catalog") when the page already
        #   registers WebMCP tools of its own that could collide.
        # @param only [Array<String>, nil] action names to expose, after the
        #   capability filter; nil means all of them.
        # @param except [Array<String>] action names to leave out; see
        #   DEFAULT_EXCEPT.
        # @param capabilities [#call] capability-name predicate.
        # @param server_opts forwarded to Portage::Ucp::Mcp::Server.build
        #   (registry:, authenticator:, rate_limiter:, logger:, journal:, ...).
        def initialize(adapter:, prefix: nil, only: nil, except: DEFAULT_EXCEPT, capabilities: DEFAULT_CAPABILITIES,
                       **server_opts)
          @prefix = prefix.to_s
          registry = server_opts.fetch(:registry) { Portage::Ucp.configuration.registry }
          @server = Portage::Ucp::Mcp::Server.build(adapter: adapter, **server_opts, registry: registry)
          capability_of = capability_map(registry, adapter)
          selected = ->(action) { selected?(action, capability_of[action], capabilities, only, except) }
          @tools = listed_tools.filter_map do |tool|
            action = tool[:name].to_s
            decorate(tool, action, capability_of[action]) if selected.call(action)
          end.freeze
          @by_action = @tools.to_h { |tool| [tool["action"], tool] }
        end

        def exposes?(action) = @by_action.key?(action.to_s)
        def fetch(action) = @by_action.fetch(action.to_s)
        def actions = @by_action.keys

        private

        def capability_map(registry, adapter)
          registry.advertised(adapter).each_with_object({}) do |capability, map|
            capability.actions.each_key { |action| map[action.to_s] = capability.name }
          end
        end

        def listed_tools
          response = @server.handle({ jsonrpc: "2.0", id: 0, method: "tools/list", params: {} })
          response.dig(:result, :tools) || []
        end

        def selected?(action, capability_name, capabilities, only, except)
          return false unless capability_name && capabilities.call(capability_name)
          return false if only && !Array(only).map(&:to_s).include?(action)

          !Array(except).map(&:to_s).include?(action)
        end

        def decorate(tool, action, capability_name)
          schema = stringify(tool[:inputSchema] || {})
          mutating = schema.fetch("properties", {}).key?("idempotency_key")
          {
            "name" => "#{@prefix}#{action}", "action" => action, "capability" => capability_name,
            "title" => action.split("_").map(&:capitalize).join(" "),
            "description" => ToolSchemas::DESCRIPTIONS.fetch(action) { "#{capability_name}##{action}" },
            "inputSchema" => typed(schema),
            "annotations" => { "readOnlyHint" => !mutating,
                               "consequentialHint" => CONSEQUENTIAL_ACTIONS.include?(action) },
            "mutating" => mutating
          }
        end

        # The page fills idempotency_key itself when the agent leaves it out
        # (see registrar.js), so it stops being required on this side.
        def typed(schema)
          properties = schema.fetch("properties", {}).to_h do |name, property|
            [name, property.empty? ? ToolSchemas::PARAMETER_SCHEMAS.fetch(name, property) : property]
          end
          schema.except("$schema").merge(
            "properties" => properties,
            "required" => Array(schema["required"]) - ["idempotency_key"]
          )
        end

        def stringify(value)
          case value
          when Hash then value.to_h { |k, v| [k.to_s, stringify(v)] }
          when Array then value.map { |v| stringify(v) }
          else value
          end
        end
      end
    end
  end
end
