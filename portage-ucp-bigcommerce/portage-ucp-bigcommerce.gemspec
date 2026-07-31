require_relative "lib/portage/ucp/bigcommerce/version"

Gem::Specification.new do |spec|
  spec.name = "portage-ucp-bigcommerce"
  spec.version = Portage::Ucp::BigCommerce::VERSION
  spec.summary = "BigCommerce adapter for portage-ucp — standard catalog/cart/checkout/order over MCP and UCP"
  spec.description = "Implements Portage::Ucp::Adapter against a BigCommerce store's v3 Catalog/Carts/" \
                     "Checkouts APIs and v2 Orders API. Generic only — no merchant-specific business logic. " \
                     "Plain Net::HTTP, no bigcommerce/api runtime dependency."
  spec.authors = ["Tom Whitbread"]
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir["lib/**/*.rb", "exe/*", "README.md", "LICENSE"]
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "portage-ucp", "~> 0.1"

  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "rubocop"
  spec.add_development_dependency "webmock", "~> 3.24"
  spec.add_development_dependency "yard"
  spec.metadata["rubygems_mfa_required"] = "true"
end
