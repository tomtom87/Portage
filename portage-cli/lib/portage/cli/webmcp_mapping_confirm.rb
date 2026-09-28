module Portage
  module Cli
    # Turns a `Portage::Ucp::WebMcp::Matcher` proposal into `tool_names:`
    # `Buy#webmcp_flow` can pass to `WebMcp.connect`, enforcing Phase 2's
    # confirm-before-mutate rule (docs/plans/webmcp-universal-outbound.md):
    # a read action (`search_catalog`, `get_product`, `get_cart`) is usable
    # straight off the proposal — wrong at worst wastes a call. A mutating
    # action (`create_cart`, `update_cart`, `create_checkout`) needs
    # confirmation first, since a wrong guess there could add to, discard,
    # or charge a stranger's cart.
    #
    # The prompt quotes a mutating tool's own `description` as what it is —
    # page content, therefore untrusted — never as an instruction. Nothing
    # here executes, follows, or acts on anything the description says; it
    # is printed for the shopper to read and nothing more.
    class WebmcpMappingConfirm
      READ_ACTIONS = %w[search_catalog get_product get_cart].freeze

      # @param interactive [Boolean] whether a prompt can actually be shown
      #   and answered — false under --json or with no TTY on stdin (the
      #   caller decides; this class has no opinion on how). false means a
      #   proposal with any mutating action is always refused.
      def initialize(interactive:, input: $stdin, output: $stdout)
        @interactive = interactive
        @input = input
        @output = output
      end

      # @param proposal [Hash{String => Matcher::Proposal}]
      # @param tools [Array<Hash>] the page's own tools, so the prompt can
      #   quote a mutating tool's description.
      # @return [Hash{String => String}, nil] a tool_names: hash covering
      #   every proposed action, or nil when a mutating action was proposed
      #   and couldn't be confirmed — no TTY, --json, or the shopper
      #   declined. Never returns a partial mapping: either every mutating
      #   action in the proposal is approved, or none of them are used.
      def call(proposal, tools)
        reads = proposal.slice(*READ_ACTIONS).transform_values(&:tool)
        mutating = proposal.except(*READ_ACTIONS)
        return reads if mutating.empty?
        return nil unless confirmed?(mutating, tools)

        reads.merge(mutating.transform_values(&:tool))
      end

      private

      def confirmed?(mutating, tools) = @interactive && approve?(mutating, tools)

      def approve?(mutating, tools)
        @output.puts "This page's WebMCP tools weren't recognized as a known store platform. Based on their " \
                     "names and schemas, here's the proposed mapping for cart/checkout actions — the " \
                     "description text is quoted from the page itself, not a trusted instruction:"
        mutating.each { |action, match| describe(action, match, tools) }
        @output.print "Use this mapping? [y/N] "
        @output.flush
        @input.gets.to_s.strip.downcase == "y"
      end

      def describe(action, match, tools)
        tool = tools.find { |t| (t["name"] || t[:name]).to_s == match.tool }
        description = tool && (tool["description"] || tool[:description])
        @output.puts "  #{action} -> #{match.tool} (confidence #{match.confidence}) — #{match.reason}"
        @output.puts "    page description: #{description.inspect}" if description
      end
    end
  end
end
