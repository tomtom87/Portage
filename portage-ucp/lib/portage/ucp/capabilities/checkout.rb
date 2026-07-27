module Portage
  module Ucp
    module Capabilities
      CHECKOUT = Portage::Ucp::Capability.new(
        name: "dev.ucp.shopping.checkout",
        version: "1",
        actions: {
          "create_checkout" => :create_checkout,
          "get_checkout" => :get_checkout,
          "update_checkout" => :update_checkout,
          "complete_checkout" => :complete_checkout,
          "cancel_checkout" => :cancel_checkout
        }
      )
    end
  end
end
