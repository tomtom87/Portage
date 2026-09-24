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
      # @return [Boolean] whether portage-ucp-webmcp could be loaded.
      #   Memoized: `require` runs once per process.
      def self.available?
        return @available unless @available.nil?

        @available = begin
          require "portage/ucp/webmcp"
          true
        rescue LoadError
          false
        end
      end
    end
  end
end
