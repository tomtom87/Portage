require_relative "lib/ucp_mcp/shopify/version"

Gem::Specification.new do |spec|
  spec.name = "ucp_mcp-shopify"
  spec.version = UcpMcp::Shopify::VERSION
  spec.summary = "Shopify adapter for ucp_mcp — standard catalog/cart/checkout/order over MCP and UCP"
  spec.description = "Implements UcpMcp::Adapter against Shopify's Admin (catalog, order) and " \
                     "Storefront (cart, checkout) GraphQL APIs. Generic only — no merchant-specific " \
                     "business logic. Plain Net::HTTP, no shopify_api runtime dependency."
  spec.authors = ["Tom Whitbread"]
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE"]
  spec.require_paths = ["lib"]

  spec.add_dependency "ucp_mcp", "~> 0.1"

  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "rubocop"
  spec.add_development_dependency "webmock", "~> 3.24"
  spec.add_development_dependency "yard"
  spec.metadata["rubygems_mfa_required"] = "true"
end
