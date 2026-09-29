module Portage
  module Cli
    # docs/plans/handoff-reconcile.md Phase 4 — `portage-ucp-webmcp` is
    # optional at runtime, not in portage-cli's gemspec, same posture as
    # `Decisions.available?` for `portage-ucp-decision` and
    # `Resolver.build_adapter` for a platform adapter gem: `require`, then
    # rescue LoadError, so `gem install portage-cli` stays light and only a
    # caller who actually passes `Buy.new(webmcp_bridge:)` ever needs it
    # installed.
    module Webmcp
      # WebMcp::Autofill, Presets, Matcher and Fingerprint, which the CLI
      # calls, first shipped in portage-ucp-webmcp 0.2.0. An older install
      # counts as not installed rather than failing with a NameError later.
      MIN_VERSION = "0.2.0".freeze

      # @return [Boolean] whether a new-enough portage-ucp-webmcp could be
      #   loaded. Memoized: `require` runs once per process.
      def self.available?
        return @available unless @available.nil?

        @available = begin
          require "portage/ucp/webmcp"
          supported?(Portage::Ucp::WebMcp::VERSION)
        rescue LoadError
          false
        end
      end

      def self.supported?(version) = Gem::Version.new(version) >= Gem::Version.new(MIN_VERSION)
    end
  end
end
