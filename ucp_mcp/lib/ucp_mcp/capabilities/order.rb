module UcpMcp
  module Capabilities
    ORDER = UcpMcp::Capability.new(
      name: "dev.ucp.shopping.order",
      version: "1",
      actions: { "get_order" => :get_order }
    )
  end
end
