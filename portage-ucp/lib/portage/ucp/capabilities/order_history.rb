module Portage
  module Ucp
    module Capabilities
      # Portage-only extension, not part of the UCP spec: dev.ucp.shopping.order
      # only reads an order by id, with no way to find one without it. Same
      # Portage-owned namespacing as Capabilities::REORDER. Mcp::Server gates
      # list_orders behind the authenticator even though it reads (see
      # Mcp::Server::AUTH_REQUIRED_READS) — an open list would hand any
      # caller every customer's orders.
      ORDER_HISTORY = Portage::Ucp::Capability.new(
        name: "app.portage-ucp.order_history",
        version: "1",
        actions: { "list_orders" => :list_orders }
      )
    end
  end
end
