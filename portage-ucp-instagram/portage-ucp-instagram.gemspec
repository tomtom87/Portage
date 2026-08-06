require_relative "lib/portage/ucp/instagram/version"

Gem::Specification.new do |spec|
  spec.name = "portage-ucp-instagram"
  spec.version = Portage::Ucp::Instagram::VERSION
  spec.summary = "Instagram/Facebook Shops adapter for portage-ucp — catalog/order over MCP and UCP, " \
                 "redirect-link checkout"
  spec.description = "Implements Portage::Ucp::Adapter against Meta's Graph API Commerce Catalog. Catalog " \
                     "is real; checkout is redirect-link only (to each product's own merchant-hosted URL) " \
                     "since Meta's public API has no cart/checkout endpoint for website-checkout catalogs, " \
                     "and none at all for native Instagram/Facebook checkout. Generic only — no merchant-" \
                     "specific business logic. Plain Net::HTTP, no Facebook SDK runtime dependency."
  spec.authors = ["Tom Whitbread"]
  spec.license = "MIT"
  spec.homepage = "https://github.com/tomtom87/Portage/tree/main/portage-ucp-instagram"
  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE", "CHANGELOG.md"]
  spec.bindir = "exe"
  spec.require_paths = ["lib"]

  spec.add_dependency "portage-ucp", "~> 0.1"

  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "rubocop", "~> 1.88"
  spec.add_development_dependency "webmock", "~> 3.24"
  spec.add_development_dependency "yard", "~> 0.9"
  spec.metadata["source_code_uri"] = "https://github.com/tomtom87/Portage/tree/main/portage-ucp-instagram"
  spec.metadata["changelog_uri"] = "https://github.com/tomtom87/Portage/blob/main/portage-ucp-instagram/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"
end
