require_relative "lib/ucp_mcp/version"

Gem::Specification.new do |spec|
  spec.name = "ucp_mcp"
  spec.version = UcpMcp::VERSION
  spec.summary = "Expose a commerce backend to AI shopping agents over MCP and UCP"
  spec.description = "Protocol-only core gem: Adapter contract, capability registry, " \
                      "manifest builder, and an MCP server wrapper. No commerce-backend deps."
  spec.authors = ["Tom Whitbread"]
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE"]
  spec.require_paths = ["lib"]

  spec.add_dependency "mcp", "~> 0.24"

  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "rubocop"
  spec.add_development_dependency "yard"
end
