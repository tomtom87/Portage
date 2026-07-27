module Portage
  module Ucp
    module Capabilities
      CART = Portage::Ucp::Capability.new(
        name: "dev.ucp.shopping.cart",
        version: "1",
        actions: {
          "create_cart" => :create_cart,
          "get_cart" => :get_cart,
          "update_cart" => :update_cart,
          "cancel_cart" => :cancel_cart
        }
      )
    end
  end
end
