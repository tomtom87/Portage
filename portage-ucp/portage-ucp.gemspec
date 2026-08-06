require_relative "lib/portage/ucp/version"

Gem::Specification.new do |spec|
  spec.name = "portage-ucp"
  spec.version = Portage::Ucp::VERSION
  spec.summary = "Expose a commerce backend to AI shopping agents over MCP and UCP"
  spec.description = "Protocol-only core gem: Adapter contract, capability registry, " \
                     "manifest builder, and an MCP server wrapper. No commerce-backend deps."
  spec.authors = ["Tom Whitbread"]
  spec.license = "MIT"
  spec.homepage = "https://github.com/tomtom87/Portage/tree/main/portage-ucp"
  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir["lib/**/*.rb", "exe/*", "schemas/**/*.json", "README.md", "LICENSE", "CHANGELOG.md"]
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "base64", "~> 0.2"
  spec.add_dependency "json_schemer", "~> 2.5"
  spec.add_dependency "mcp", "~> 0.24"
  spec.add_dependency "rack", "~> 3.0"

  spec.add_development_dependency "rack-test", "~> 2.1"
  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "rubocop", "~> 1.88"
  spec.add_development_dependency "webmock", "~> 3.24"
  spec.add_development_dependency "yard", "~> 0.9"
  spec.metadata["source_code_uri"] = "https://github.com/tomtom87/Portage/tree/main/portage-ucp"
  spec.metadata["changelog_uri"] = "https://github.com/tomtom87/Portage/blob/main/portage-ucp/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"
end
