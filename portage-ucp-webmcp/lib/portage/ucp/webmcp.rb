require "portage/ucp"
require "portage/ucp/client"

require_relative "webmcp/version"
require_relative "webmcp/errors"
require_relative "webmcp/assets"
require_relative "webmcp/tool_catalog"
require_relative "webmcp/registrar"
require_relative "webmcp/rack/call_endpoint"
require_relative "webmcp/rack/script_endpoint"
require_relative "webmcp/rack/app"
require_relative "webmcp/bridges/script_evaluator"
require_relative "webmcp/jsonable"
require_relative "webmcp/page_wait"
require_relative "webmcp/transport"
require_relative "webmcp/capabilities"
require_relative "webmcp/fingerprint"
require_relative "webmcp/presets"
require_relative "webmcp/matcher"

module Portage
  module Ucp
    # WebMCP (https://webmachinelearning.github.io/webmcp/) as one more way
    # to reach the Adapter contract, next to classic MCP (stdio, Streamable
    # HTTP) and native UCP — not a commerce backend of its own.
    #
    # Inbound (merchant side): ToolCatalog + Rack::App register a
    # Portage-powered store's tools on its pages via `document.modelContext`,
    # each call routed back into Portage::Ucp::Mcp::Server.
    #
    # Outbound (agent side): Transport + a Bridge let a portage-ucp-client
    # Session drive the WebMCP tools any page registers, Portage-powered or
    # not.
    module WebMcp
      # Session over a page's WebMCP tools. Pass a Bridge, or `evaluate:` (a
      # callable that evaluates a JS expression in the page and returns what
      # its promise resolves to) to get the default ScriptEvaluator bridge.
      #
      #   session = Portage::Ucp::WebMcp.connect(
      #     bridge: Portage::Ucp::WebMcp::Bridges::ScriptEvaluator.ferrum(browser.page)
      #   )
      #   session.search_catalog(query: "mug")
      #
      # @param capabilities [Array<String>, nil] nil (the default) derives
      #   them from the tools the page registers right now (see
      #   Capabilities), which reads the page once here, so a BridgeError can
      #   raise from connect itself.
      # @param preset [Symbol, nil] :auto (the default) detects a known
      #   platform from the page's own tools (Presets.detect) and, on a
      #   match, uses its tool_names:/wire: — reading the page once more, for
      #   the same BridgeError reason as capabilities: above. nil turns
      #   presets off entirely (today's behavior, before this parameter
      #   existed). A Symbol (:shopify) forces that preset without reading
      #   the page to detect it. Either way, an explicit tool_names:/wire: in
      #   transport_options wins over the preset's own — tool_names: key by
      #   key, wire: outright — since a caller who bothered to pass one knows
      #   this page better than a fingerprint match does.
      # @param transport_options [Hash] forwarded to Transport (prefix:,
      #   tool_names:, wire:, reregister_wait:).
      def self.connect(bridge: nil, evaluate: nil, capabilities: nil, preset: :auto, **transport_options)
        bridge ||= Bridges::ScriptEvaluator.new(evaluate: evaluate) if evaluate
        raise ArgumentError, "connect requires either bridge: or evaluate:" unless bridge

        resolved = resolve_preset(bridge, preset)
        transport = Transport.new(bridge: bridge, **transport_options_for(resolved, transport_options))
        Portage::Ucp::Client::Session.new(
          transport: transport,
          capabilities: capabilities || Capabilities.for(transport, handoff_checkout: resolved&.handoff_checkout)
        )
      end

      # Page script installing a spec-shaped `document.modelContext` where
      # the browser has none — inject as an init script before navigation so
      # pages register into something the consumer can read.
      def self.polyfill_js = Assets.read("polyfill.js")

      def self.resolve_preset(bridge, preset)
        case preset
        when :auto then (name = Presets.detect(bridge.list_tools)) && Presets.fetch(name)
        when nil then nil
        else Presets.fetch(preset)
        end
      end
      private_class_method :resolve_preset

      def self.transport_options_for(preset, transport_options)
        return transport_options unless preset

        { wire: preset.wire }.merge(transport_options)
                             .merge(tool_names: preset.tool_names.merge(transport_options[:tool_names] || {}))
      end
      private_class_method :transport_options_for
    end
  end
end
