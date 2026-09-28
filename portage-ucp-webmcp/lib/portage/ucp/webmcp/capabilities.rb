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

        # Reads the page's tools once, through the transport's cache.
        #
        # @param transport [Transport]
        # @return [Array<String>]
        def self.for(transport)
          STARTING_ACTIONS.filter_map do |capability, actions|
            capability if actions.any? { |action| transport.answers?(action) }
          end
        end
      end
    end
  end
end
