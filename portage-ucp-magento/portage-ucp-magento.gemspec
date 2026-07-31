require_relative "lib/portage/ucp/magento/version"

Gem::Specification.new do |spec|
  spec.name = "portage-ucp-magento"
  spec.version = Portage::Ucp::Magento::VERSION
  spec.summary = "Magento/Adobe Commerce adapter for portage-ucp — standard catalog/cart/checkout/order " \
                 "over MCP and UCP"
  spec.description = "Implements Portage::Ucp::Adapter against a Magento/Adobe Commerce site's REST v1 API " \
                     "(admin-token catalog/order, anonymous guest-cart cart/checkout). Generic only — no " \
                     "merchant-specific business logic. Plain Net::HTTP, no Magento PHP SDK dependency."
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
