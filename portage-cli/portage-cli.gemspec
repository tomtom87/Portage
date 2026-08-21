require_relative "lib/portage/cli/version"

Gem::Specification.new do |spec|
  spec.name = "portage-cli"
  spec.version = Portage::Cli::VERSION
  spec.summary = "portage — one CLI command to buy from any store, native UCP or not"
  spec.description = "Ships the `portage` executable. `portage buy <url>` tries native UCP discovery first " \
                     "(zero credentials, works on any store that's opted in), falls back to a portage-ucp-* " \
                     "platform adapter only when this process already has that platform's own credentials " \
                     "in env (i.e. it's your own store or one you're integrated with), and otherwise says so " \
                     "plainly — never scrapes or session-hijacks as an anonymous shopper. `portage find` " \
                     "covers the no-URL case: ask an allowlist, DuckDuckGo, Brave, or a Google Programmable " \
                     "Search engine which stores might sell something, keep the ones answering " \
                     "/.well-known/ucp, and search their catalogs — documented APIs only, no SERP scraping. " \
                     "Depends on " \
                     "portage-ucp (for platform detection via Resolver) and portage-ucp-client (for the " \
                     "actual buy calls); no single adapter gem is a hard dependency."
  spec.authors = ["Tom Whitbread"]
  spec.license = "MIT"
  spec.homepage = "https://github.com/tomtom87/Portage/tree/main/portage-cli"
  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir["lib/**/*.rb", "exe/*", "README.md", "LICENSE", "CHANGELOG.md"]
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "portage-ucp", "~> 0.2"
  spec.add_dependency "portage-ucp-client", "~> 0.2"

  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "rubocop", "~> 1.88"
  spec.add_development_dependency "webmock", "~> 3.24"
  spec.add_development_dependency "yard", "~> 0.9"
  spec.metadata["source_code_uri"] = "https://github.com/tomtom87/Portage/tree/main/portage-cli"
  spec.metadata["changelog_uri"] = "https://github.com/tomtom87/Portage/blob/main/portage-cli/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"
end
