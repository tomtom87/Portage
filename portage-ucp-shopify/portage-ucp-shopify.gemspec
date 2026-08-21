require_relative "lib/portage/ucp/shopify/version"

Gem::Specification.new do |spec|
  spec.name = "portage-ucp-shopify"
  spec.version = Portage::Ucp::Shopify::VERSION
  spec.summary = "Shopify adapter for portage-ucp — standard catalog/cart/checkout/order over MCP and UCP"
  spec.description = "Implements Portage::Ucp::Adapter against Shopify's Admin (catalog, order) and " \
                     "Storefront (cart, checkout) GraphQL APIs. Generic only — no merchant-specific " \
                     "business logic. Plain Net::HTTP, no shopify_api runtime dependency."
  spec.authors = ["Tom Whitbread"]
  spec.license = "MIT"
  spec.homepage = "https://github.com/tomtom87/Portage/tree/main/portage-ucp-shopify"
  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir["lib/**/*.rb", "exe/*", "README.md", "LICENSE", "CHANGELOG.md"]
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "portage-ucp", "~> 0.2"

  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "rubocop", "~> 1.88"
  spec.add_development_dependency "webmock", "~> 3.24"
  spec.add_development_dependency "yard", "~> 0.9"
  spec.metadata["source_code_uri"] = "https://github.com/tomtom87/Portage/tree/main/portage-ucp-shopify"
  spec.metadata["changelog_uri"] = "https://github.com/tomtom87/Portage/blob/main/portage-ucp-shopify/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"
end
