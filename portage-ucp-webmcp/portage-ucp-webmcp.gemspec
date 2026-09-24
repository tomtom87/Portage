require_relative "lib/portage/ucp/webmcp/version"

Gem::Specification.new do |spec|
  spec.name = "portage-ucp-webmcp"
  spec.version = Portage::Ucp::WebMcp::VERSION
  spec.summary = "WebMCP transport for portage-ucp — reach the same Adapter contract through a browser page's " \
                 "document.modelContext"
  spec.description = "WebMCP as a transport, not a commerce backend. Inbound: registers a Portage-powered " \
                     "store's catalog/cart/checkout tools on the page via document.modelContext, each one " \
                     "calling back into the same Portage::Ucp::Mcp::Server every other transport uses. " \
                     "Outbound: a portage-ucp-client transport that discovers and calls the WebMCP tools any " \
                     "page registers, through whatever browser driver the caller already has (Ferrum, " \
                     "Playwright, Selenium, or a plain JS-evaluating callable). No adapter gem is a dependency."
  spec.authors = ["Tom Whitbread"]
  spec.license = "MIT"
  spec.homepage = "https://github.com/tomtom87/Portage/tree/main/portage-ucp-webmcp"
  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir["lib/**/*.rb", "lib/**/*.js", "README.md", "LICENSE", "CHANGELOG.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "portage-ucp", "~> 0.8"
  spec.add_dependency "portage-ucp-client", "~> 0.6", ">= 0.6.2"
  spec.add_dependency "rack", "~> 3.0"

  spec.add_development_dependency "ferrum", "~> 0.15"
  spec.add_development_dependency "rack-test", "~> 2.1"
  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "rubocop", "~> 1.88"
  spec.add_development_dependency "webmock", "~> 3.24"
  spec.add_development_dependency "webrick", "~> 1.8"
  spec.add_development_dependency "yard", "~> 0.9"
  spec.metadata["source_code_uri"] = "https://github.com/tomtom87/Portage/tree/main/portage-ucp-webmcp"
  spec.metadata["changelog_uri"] = "https://github.com/tomtom87/Portage/blob/main/portage-ucp-webmcp/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"
end
