require_relative "../handoff_only"

module Portage
  module Cli
    module BrowserProfile
      # The domain allowlist Phase 6 requires: driving the profile browser
      # (evaluating WebMCP tool calls, filling checkout fields, navigating)
      # is limited to the store being bought from, plus its checkout host
      # once one is known. Anything else stops the run — see Bridge and
      # DomainNotAllowedError.
      #
      # Reuses HandoffOnly's own host normalization/matching (a base host
      # matches itself or any subdomain, "www." stripped, a full URL or a
      # bare host both accepted) rather than a second copy of that logic.
      class Allowlist
        def initialize(hosts: [])
          @hosts = hosts.filter_map { |h| HandoffOnly.normalize_entry(h) }
        end

        def hosts = @hosts.dup

        def allowed?(host) = HandoffOnly.matches_any?(host, @hosts)

        # Adds a host once it's known to be exactly what Portage itself is
        # deliberately navigating to (the checkout URL a hand-off is about
        # to open) — never called for a navigation a driven page made on
        # its own; that's what #allowed? guards against.
        # @return [String, nil] the normalized host that was added (or
        #   already present), nil when `host_or_url` didn't parse to one.
        def permit!(host_or_url)
          normalized = HandoffOnly.normalize_entry(host_or_url)
          return nil unless normalized

          @hosts << normalized unless @hosts.include?(normalized)
          normalized
        end
      end
    end
  end
end
