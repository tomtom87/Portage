require_relative "lib/portage/ucp/journal/version"

Gem::Specification.new do |spec|
  spec.name = "portage-ucp-journal"
  spec.version = Portage::Ucp::Journal::VERSION
  spec.summary = "Buyer-side purchase journal + injectable Store abstraction for portage-ucp"
  spec.description = "An append-only, consumer-swappable record of every purchase a Dispatcher completes " \
                     "(store origin, source, product, amount in minor units, order id, idempotency key), " \
                     "built on a small Store interface in the rate_limiter/authenticator mold — the shared " \
                     "persistence seam design-log §22 asks for so a future console or scheduler gem doesn't " \
                     "each grow an incompatible one. Zero runtime dependency on portage-ucp itself; wires in " \
                     "via Dispatcher's optional journal: argument."
  spec.authors = ["Tom Whitbread"]
  spec.license = "MIT"
  spec.homepage = "https://github.com/tomtom87/Portage/tree/main/portage-ucp-journal"
  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE", "CHANGELOG.md"]
  spec.require_paths = ["lib"]

  spec.add_development_dependency "portage-ucp", "~> 0.5"
  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "rubocop", "~> 1.88"
  spec.add_development_dependency "yard", "~> 0.9"
  spec.metadata["source_code_uri"] = "https://github.com/tomtom87/Portage/tree/main/portage-ucp-journal"
  spec.metadata["changelog_uri"] = "https://github.com/tomtom87/Portage/blob/main/portage-ucp-journal/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"
end
