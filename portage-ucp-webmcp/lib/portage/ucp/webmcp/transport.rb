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
        # How long a call waits for a tool the page dropped mid-re-render to
        # come back (see #execute), and how often it looks.
        REREGISTER_WAIT = 2.0
        REREGISTER_POLL = 0.25

        attr_reader :bridge

        def initialize(bridge:, prefix: nil, tool_names: {}, wire: :auto, reregister_wait: REREGISTER_WAIT)
          raise ArgumentError, "wire: must be one of #{WIRES.join(', ')}" unless WIRES.include?(wire)

          @bridge = bridge
          @prefix = prefix.to_s
          @tool_names = tool_names.to_h { |action, tool| [action.to_s, tool.to_s] }
          @wire = wire
          @reregister_wait = reregister_wait
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
          result(execute(name.to_s, tool["name"], Jsonable.call(input)))
        end

        private

        # A page can drop every tool and register them again while it
        # re-renders — confirmed live on Shopify storefronts, where the page's
        # own `add_to_cart` leaves `navigator.modelContext` empty for ~500ms
        # before all 11 tools come back. A tool #resolve just found that the
        # page now says isn't registered is that gap, not a missing tool, and
        # the call never ran, so wait for it and send the call again. Past
        # `reregister_wait:` it's reported like any other miss.
        #
        # The wait is a plain `sleep`, so it blocks the calling thread (see
        # the README's "Timeouts"). One monotonic deadline covers the whole
        # call: it's set before the first attempt, a retry never resets it,
        # the retried bridge calls count against it, and no sleep runs past
        # it. So a miss costs at most `reregister_wait:` plus the one bridge
        # call in flight when it expires.
        def execute(action, tool_name, input)
          deadline = monotonic_now + @reregister_wait
          begin
            @bridge.execute_tool(tool_name, input)
          rescue ToolNotFoundError
            raise(refresh!.then { not_found(action, [tool_name]) }) if monotonic_now >= deadline

            sleep((deadline - monotonic_now).clamp(0, REREGISTER_POLL))
            retry
          end
        end

        def monotonic_now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

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
      end
    end
  end
end
