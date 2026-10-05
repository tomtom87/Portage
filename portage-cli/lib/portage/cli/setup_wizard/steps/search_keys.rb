require_relative "env_keys_step"

module Portage
  module Cli
    class SetupWizard
      module Steps
        # Step 2 (docs/plans/buy-skill-and-local-browser.md Phase 4): Brave
        # and Google CSE search keys, written to ~/.portage/.env. See
        # Doctor#search_backend_finding — with neither set, `find`/`buy`
        # with no URL only ever resolves DuckDuckGo's Instant Answer API,
        # which is keyless but only ever matches a specific brand/product
        # name, not an open-ended query ("coffee", "hiking boots").
        class SearchKeys < EnvKeysStep
          FIELDS = {
            "BRAVE_SEARCH_API_KEY" => "Brave Search API key",
            "GOOGLE_CSE_KEY" => "Google Programmable Search API key",
            "GOOGLE_CSE_CX" => "Google Programmable Search engine id (cx)"
          }.freeze

          # Google's `cx` names which engine to query, not a credential —
          # only the two API keys are secrets that never echo back.
          SECRET = %w[BRAVE_SEARCH_API_KEY GOOGLE_CSE_KEY].freeze

          def title = "Search API keys"
          def default_yes? = true

          private

          def intro
            "DuckDuckGo's free API is already active and needs no key, but only resolves a " \
              "specific brand/product name — set either Brave's key, or both Google fields, for " \
              "real open-ended search. Neither key is echoed back; Enter keeps whatever's " \
              "already set."
          end

          def unchanged_message = "Left search API keys unchanged."
          def secret?(var) = SECRET.include?(var)
        end
      end
    end
  end
end
