module Portage
  module Ucp
    module WebMcp
      # The UCP capabilities a page's WebMCP tools add up to, so a Session
      # over them answers #advertises? with true/false instead of nil. A page
      # has no manifest to read them from (unlike Client.discover), and a
      # Session built without them can't gate on them: before this,
      # Cli::Buy#webmcp_flow's cart/checkout check always failed against a
      # real page.
      #
      # A capability counts when the page answers the action that starts it
      # (after Transport's own tool_names:/prefix: resolution), not every
      # action under it: a catalog with search but no lookup is still a
      # catalog.
      module Capabilities
        STARTING_ACTIONS = {
          "dev.ucp.shopping.catalog" => %w[search_catalog get_product lookup_catalog],
          "dev.ucp.shopping.cart" => %w[create_cart],
          "dev.ucp.shopping.checkout" => %w[create_checkout],
          "dev.ucp.shopping.order" => %w[get_order]
        }.freeze

        CHECKOUT = "dev.ucp.shopping.checkout".freeze

        # Reads the page's tools once, through the transport's cache.
        #
        # @param transport [Transport]
        # @param handoff_checkout [String, nil] a preset's hand-off-only
        #   checkout tool (e.g. Shopify's `proceed_to_checkout`) — decision 1
        #   in docs/plans/webmcp-universal-outbound.md: a page that answers
        #   it counts as advertising checkout even though it only navigates
        #   the shopper to the store's own checkout, not `create_checkout`.
        # @return [Array<String>]
        def self.for(transport, handoff_checkout: nil)
          STARTING_ACTIONS.filter_map do |capability, actions|
            answers = actions.any? { |action| transport.answers?(action) }
            answers ||= capability == CHECKOUT && handoff_checkout && transport.answers?(handoff_checkout)
            capability if answers
          end
        end
      end
    end
  end
end
