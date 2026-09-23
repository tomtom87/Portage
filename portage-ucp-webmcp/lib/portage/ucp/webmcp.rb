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
require_relative "webmcp/transport"

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
      # @param transport_options [Hash] forwarded to Transport (prefix:,
      #   tool_names:, wire:, reregister_wait:).
      def self.connect(bridge: nil, evaluate: nil, capabilities: nil, **transport_options)
        bridge ||= Bridges::ScriptEvaluator.new(evaluate: evaluate) if evaluate
        raise ArgumentError, "connect requires either bridge: or evaluate:" unless bridge

        Portage::Ucp::Client::Session.new(transport: Transport.new(bridge: bridge, **transport_options),
                                          capabilities: capabilities)
      end

      # Page script installing a spec-shaped `document.modelContext` where
      # the browser has none — inject as an init script before navigation so
      # pages register into something the consumer can read.
      def self.polyfill_js = Assets.read("polyfill.js")
    end
  end
end
