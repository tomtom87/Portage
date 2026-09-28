module Portage
  module Cli
    # Where the repo's own `known-stores/{stores,products}.json` (docs/plans/
    # buy-skill-and-local-browser.md Phase 2c) are published for a fresh
    # install to fetch: the same jsdelivr `@main` channel AgentProfileUrl
    # already uses for the agent profile. Free GitHub, no Actions — a new
    # entry reaches every install on its next refresh as soon as a PR
    # merges, with no gem/brew release to wait on.
    module KnownStoresUrl
      BASE = "https://cdn.jsdelivr.net/gh/tomtom87/Portage@main/portage-cli/known-stores".freeze
      STORES = "#{BASE}/stores.json".freeze
      PRODUCTS = "#{BASE}/products.json".freeze
    end
  end
end
