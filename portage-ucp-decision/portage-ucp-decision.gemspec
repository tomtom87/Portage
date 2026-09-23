require_relative "lib/portage/ucp/decision/version"

Gem::Specification.new do |spec|
  spec.name = "portage-ucp-decision"
  spec.version = Portage::Ucp::Decision::VERSION
  spec.summary = "System One decision layer for portage-ucp — offer ranking, escalation, confidence, policy"
  spec.description = "The judgment calls between the agent loop and the Adapter/client layer, as typed, " \
                     "inspectable decisions instead of control flow scattered across skill instructions " \
                     "and the CLI: which offer to pick (OfferRanking), hand off vs. keep going " \
                     "(EscalationPolicy), whether a result is confident enough to act on unattended " \
                     "(ConfidenceGate), and a typed wrapper around Portage::Ucp::PolicyGuard (PolicyCheck). " \
                     "See docs/plans/system-one-decision-layer.md."
  spec.authors = ["Tom Whitbread"]
  spec.license = "MIT"
  spec.homepage = "https://github.com/tomtom87/Portage/tree/main/portage-ucp-decision"
  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE", "CHANGELOG.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "faraday", ">= 2.0"
  spec.add_dependency "portage-ucp", "~> 0.9"

  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "rubocop", "~> 1.88"
  spec.add_development_dependency "webmock", "~> 3.24"
  spec.add_development_dependency "yard", "~> 0.9"
  spec.metadata["source_code_uri"] = "https://github.com/tomtom87/Portage/tree/main/portage-ucp-decision"
  spec.metadata["changelog_uri"] = "https://github.com/tomtom87/Portage/blob/main/portage-ucp-decision/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"
end
