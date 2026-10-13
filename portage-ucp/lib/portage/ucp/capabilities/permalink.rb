module Portage
  module Ucp
    module Capabilities
      # schemas/shopping/permalink.json — a browser redirect endpoint the
      # business serves (services/shopping/permalink.openapi.json), not an
      # MCP action, so `actions` is empty and advertisement runs off
      # Adapter#permalink_endpoint, whose value is the required
      # `config.endpoint`.
      PERMALINK = Portage::Ucp::Capability.new(
        name: "dev.ucp.shopping.permalink",
        version: "1",
        schema: "shopping/permalink.json",
        actions: {},
        predicate: :permalink_endpoint,
        config: ->(adapter) { { endpoint: adapter.permalink_endpoint } }
      )
    end
  end
end
