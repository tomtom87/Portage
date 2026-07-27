module Portage
  module Ucp
    module Capabilities
      CATALOG = Portage::Ucp::Capability.new(
        name: "dev.ucp.shopping.catalog",
        version: "1",
        actions: { "search_catalog" => :search_catalog, "get_product" => :get_product }
      )
    end
  end
end
