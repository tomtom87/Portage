require "json"

module Portage
  module Ucp
    module WebMcp
      # A portage-ucp-client transport (same `#call_tool(name:, arguments:,
      # meta:)` contract as Loopback/Stdio/Http) whose far end is a browser
      # page's WebMCP tools, reached through a Bridge. Session never knows the
      # difference.
      #
      # Universal by design — the page doesn't have to run Portage:
      #
      # - Tool names: Session's action name ("search_catalog") is looked up
      #   as `tool_names[action]`, then "#{prefix}#{action}", then the action
      #   itself. Map a third-party store's own names with `tool_names:`.
      # - Argument shape: per tool, from its own inputSchema. A tool whose
      #   properties nest under catalog/cart/checkout (or take `id` + `meta`)
      #   is a real-UCP-shaped tool and gets the same body
      #   Transports::Http builds (shared via Transports::UcpWireShape);
      #   anything else — including this gem's own registrar — gets
      #   Session's flat arguments, as Loopback/Stdio send them. Force one
      #   with `wire: :ucp`/`wire: :flat`.
      # - Results: a WebMCP tool can return anything. An MCP-style
      #   CallToolResult (`content`/`structuredContent`/`isError`) is
      #   unwrapped the way ToolResult unwraps one over stdio/HTTP; a JSON
      #   string is parsed; anything else comes back as-is.
      class Transport
        include Portage::Ucp::Client::Transports::UcpWireShape

        UCP_WRAPPERS = %w[catalog cart checkout].freeze
        WIRES = %i[auto flat ucp].freeze

        attr_reader :bridge

        def initialize(bridge:, prefix: nil, tool_names: {}, wire: :auto)
          raise ArgumentError, "wire: must be one of #{WIRES.join(', ')}" unless WIRES.include?(wire)

          @bridge = bridge
          @prefix = prefix.to_s
          @tool_names = tool_names.to_h { |action, tool| [action.to_s, tool.to_s] }
          @wire = wire
        end

        # Tools the page registers right now, cached until #refresh!.
        def tools
          @tools ||= @bridge.list_tools
        end

        def refresh!
          @tools = nil
          self
        end

        def call_tool(name:, arguments:, meta: nil)
          tool = resolve(name.to_s)
          input = if wire_for(tool) == :ucp
                    ucp_input(name.to_s, arguments, meta)
                  else
                    flat_input(name.to_s, arguments, meta, tool)
                  end
          result(@bridge.execute_tool(tool["name"], jsonable(input)))
        end

        private

        # A page may register tools after load (or re-register on client-side
        # navigation), so one miss re-reads the page before giving up.
        def resolve(action)
          candidates = [@tool_names[action], "#{@prefix}#{action}", action].compact.uniq
          find(candidates) || refresh!.then { find(candidates) } || raise(not_found(action, candidates))
        end

        def find(candidates)
          candidates.each do |candidate|
            tool = tools.find { |t| t["name"] == candidate }
            return tool if tool
          end
          nil
        end

        def not_found(action, candidates)
          available = tools.map { |t| t["name"] }
          ToolNotFoundError.new(
            "no WebMCP tool on this page answers #{action.inspect} (tried #{candidates.join(', ')}); page " \
            "registers: #{available.empty? ? '(none)' : available.join(', ')} — map one with tool_names:",
            available: available
          )
        end

        def wire_for(tool)
          return @wire unless @wire == :auto

          properties = (tool.dig("inputSchema", "properties") || {}).keys.map(&:to_s)
          return :ucp if properties.intersect?(UCP_WRAPPERS)
          return :ucp if properties.include?("id") && properties.include?("meta")

          :flat
        end

        # Real-UCP wire arguments are dropped the way Loopback/Stdio drop them
        # (Transports::LocalArguments) — unless this page's tool declares one
        # in its own schema, in which case it asked for it.
        #
        # `_meta` is the registrar's one reserved input key — it becomes the
        # JSON-RPC request's own `_meta`, which is where Mcp::Server reads
        # `ucp-agent.profile` from (same remap Loopback does).
        def flat_input(action, arguments, meta, tool)
          declared = (tool.dig("inputSchema", "properties") || {}).keys.map(&:to_sym)
          local = Portage::Ucp::Client::Transports::LocalArguments.strip(action, arguments)
          input = local.merge(arguments.slice(*declared))
          return input unless meta

          profile = meta[:agent_profile] || meta["agent_profile"]
          input.merge("_meta" => profile ? meta.merge("ucp-agent.profile" => profile) : meta)
        end

        # Unlike Transports::Http, a missing agent profile isn't an error
        # here: behind WebMCP the caller is the page's own browser session,
        # which the store authenticates the way it always does.
        def ucp_input(action, arguments, meta)
          idempotency_key = arguments[:idempotency_key] || arguments["idempotency_key"]
          wire = wire_arguments(action, arguments)
          profile = meta && (meta[:agent_profile] || meta["agent_profile"])
          wire_meta = {}
          wire_meta["ucp-agent"] = { "profile" => profile } if profile
          wire_meta["idempotency-key"] = idempotency_key if idempotency_key
          wire_meta.empty? ? wire : wire.merge("meta" => wire_meta)
        end

        def result(raw)
          value = raw.is_a?(String) ? parse_json(raw) : raw
          return value unless call_tool_result?(value)

          structured = Portage::Ucp::Client::ToolResult.extract({ "result" => value }, symbol_keys: false)
          return structured unless structured.nil?

          parse_json(Portage::Ucp::Client::ToolResult.text(value["content"], symbol_keys: false))
        end

        def call_tool_result?(value)
          value.is_a?(Hash) && (value.key?("content") || value.key?("structuredContent") || value.key?("isError"))
        end

        def parse_json(text)
          JSON.parse(text)
        rescue JSON::ParserError
          text
        end

        # Arguments cross into JavaScript, so value objects (a
        # Portage::Ucp::CheckoutFulfillment, say) go over as plain hashes.
        def jsonable(value)
          case value
          when Hash then value.to_h { |k, v| [k.to_s, jsonable(v)] }
          when Array then value.map { |v| jsonable(v) }
          when String, Numeric, true, false, nil then value
          else jsonable_object(value)
          end
        end

        def jsonable_object(value)
          return value.to_s if value.is_a?(Symbol) || !value.respond_to?(:to_h)

          jsonable(value.to_h)
        end
      end
    end
  end
end
