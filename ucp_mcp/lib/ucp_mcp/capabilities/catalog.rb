module UcpMcp
  module Capabilities
    CATALOG = UcpMcp::Capability.new(
      name: "dev.ucp.shopping.catalog",
      version: "1",
      actions: { "search_catalog" => :search_catalog, "get_product" => :get_product }
    )
  end
end
