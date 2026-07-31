require_relative "lib/portage/ucp/wix/version"

Gem::Specification.new do |spec|
  spec.name = "portage-ucp-wix"
  spec.version = Portage::Ucp::Wix::VERSION
  spec.summary = "Wix adapter for portage-ucp — standard catalog/cart/checkout/order over MCP and UCP"
  spec.description = "Implements Portage::Ucp::Adapter against Wix's Stores (catalog) and eCommerce " \
                     "(cart, checkout, order) REST APIs. Generic only — no merchant-specific business " \
                     "logic. Plain Net::HTTP, no wix SDK runtime dependency."
  spec.authors = ["Tom Whitbread"]
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE"]
  spec.require_paths = ["lib"]

  spec.add_dependency "portage-ucp", "~> 0.1"

  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "rubocop"
  spec.add_development_dependency "webmock", "~> 3.24"
  spec.add_development_dependency "yard"
  spec.metadata["rubygems_mfa_required"] = "true"
end
