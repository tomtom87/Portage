module Portage
  module Ucp
    module Capabilities
      ORDER = Portage::Ucp::Capability.new(
        name: "dev.ucp.shopping.order",
        version: "1",
        actions: { "get_order" => :get_order }
      )
    end
  end
end
