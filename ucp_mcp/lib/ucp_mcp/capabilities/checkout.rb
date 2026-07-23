module UcpMcp
  module Capabilities
    CHECKOUT = UcpMcp::Capability.new(
      name: "dev.ucp.shopping.checkout",
      version: "1",
      actions: {
        "create_checkout" => :create_checkout,
        "update_checkout" => :update_checkout,
        "complete_checkout" => :complete_checkout
      }
    )
  end
end
