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
  spec.homepage = "https://github.com/tomtom87/Portage/tree/main/portage-ucp-magento"
  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir["lib/**/*.rb", "exe/*", "README.md", "LICENSE", "CHANGELOG.md"]
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "portage-ucp", "~> 0.1"

  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "rubocop", "~> 1.88"
  spec.add_development_dependency "webmock", "~> 3.24"
  spec.add_development_dependency "yard", "~> 0.9"
  spec.metadata["source_code_uri"] = "https://github.com/tomtom87/Portage/tree/main/portage-ucp-magento"
  spec.metadata["changelog_uri"] = "https://github.com/tomtom87/Portage/blob/main/portage-ucp-magento/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"
end
