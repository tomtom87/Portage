require_relative "lib/portage/ucp/etsy/version"

Gem::Specification.new do |spec|
  spec.name = "portage-ucp-etsy"
  spec.version = Portage::Ucp::Etsy::VERSION
  spec.summary = "Etsy adapter for portage-ucp — catalog/order over MCP and UCP, redirect-link checkout"
  spec.description = "Implements Portage::Ucp::Adapter against Etsy's Open API v3. Catalog and order are " \
                     "real; checkout is redirect-link only (links to etsy.com) since Etsy's public API has " \
                     "no cart/checkout endpoint. Generic only — no merchant-specific business logic. Plain " \
                     "Net::HTTP, no Etsy SDK runtime dependency."
  spec.authors = ["Tom Whitbread"]
  spec.license = "MIT"
  spec.homepage = "https://github.com/tomtom87/Portage/tree/main/portage-ucp-etsy"
  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE", "CHANGELOG.md"]
  spec.bindir = "exe"
  spec.require_paths = ["lib"]

  spec.add_dependency "portage-ucp", "~> 0.4"

  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "rubocop", "~> 1.88"
  spec.add_development_dependency "webmock", "~> 3.24"
  spec.add_development_dependency "yard", "~> 0.9"
  spec.metadata["source_code_uri"] = "https://github.com/tomtom87/Portage/tree/main/portage-ucp-etsy"
  spec.metadata["changelog_uri"] = "https://github.com/tomtom87/Portage/blob/main/portage-ucp-etsy/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"
end
