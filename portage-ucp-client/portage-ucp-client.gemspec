require_relative "lib/portage/ucp/client/version"

Gem::Specification.new do |spec|
  spec.name = "portage-ucp-client"
  spec.version = Portage::Ucp::Client::VERSION
  spec.summary = "Client-side SDK for portage-ucp — act as the shopper's agent against any UCP/MCP server"
  spec.description = "Every other portage-ucp gem lets a Ruby program expose a commerce backend to agents " \
                     "(server side). This gem is the other direction: connect to somebody else's " \
                     "/.well-known/ucp manifest, or drive your own Adapter directly, and place an order " \
                     "as the client. Three transports behind one interface (loopback over an in-process " \
                     "Adapter, stdio, Streamable HTTP) — callers never know which they got. Depends only " \
                     "on portage-ucp + the mcp gem's client half; no adapter gem is a dependency."
  spec.authors = ["Tom Whitbread"]
  spec.license = "MIT"
  spec.homepage = "https://github.com/tomtom87/Portage/tree/main/portage-ucp-client"
  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE", "CHANGELOG.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "mcp", "~> 0.24"
  spec.add_dependency "portage-ucp", "~> 0.1"

  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "rubocop", "~> 1.88"
  spec.add_development_dependency "webmock", "~> 3.24"
  spec.add_development_dependency "yard", "~> 0.9"
  spec.metadata["source_code_uri"] = "https://github.com/tomtom87/Portage/tree/main/portage-ucp-client"
  spec.metadata["changelog_uri"] = "https://github.com/tomtom87/Portage/blob/main/portage-ucp-client/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"
end
