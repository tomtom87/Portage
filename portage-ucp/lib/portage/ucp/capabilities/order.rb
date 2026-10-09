module Portage
  module Ucp
    module Capabilities
      ORDER = Portage::Ucp::Capability.new(
        name: "dev.ucp.shopping.order",
        version: "1",
        schema: "shopping/order.json",
        actions: {
          "get_order" => :get_order,
          "cancel_order" => :cancel_order,
          "request_return" => :request_return,
          "refund_order" => :refund_order
        }
      )
    end
  end
end
