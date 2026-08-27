module Portage
  module Ucp
    module Capabilities
      IDENTITY_LINKING = Portage::Ucp::Capability.new(
        name: "dev.ucp.shopping.identity",
        version: "1",
        actions: { "link_identity" => :link_identity }
      )

      ALL = [CATALOG, CART, CHECKOUT, ORDER, IDENTITY_LINKING, DISCOUNT, FULFILLMENT, REORDER].freeze
    end
  end
end
