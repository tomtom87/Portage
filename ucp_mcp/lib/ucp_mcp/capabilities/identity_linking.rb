module UcpMcp
  module Capabilities
    IDENTITY_LINKING = UcpMcp::Capability.new(
      name: "dev.ucp.shopping.identity",
      version: "1",
      actions: { "link_identity" => :link_identity }
    )

    ALL = [CATALOG, CART, CHECKOUT, ORDER, IDENTITY_LINKING].freeze
  end
end
