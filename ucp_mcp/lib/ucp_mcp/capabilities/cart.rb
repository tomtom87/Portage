module UcpMcp
  module Capabilities
    CART = UcpMcp::Capability.new(
      name: "dev.ucp.shopping.cart",
      version: "1",
      actions: {
        "get_cart" => :get_cart,
        "add_line_item" => :add_line_item,
        "remove_line_item" => :remove_line_item
      }
    )
  end
end
