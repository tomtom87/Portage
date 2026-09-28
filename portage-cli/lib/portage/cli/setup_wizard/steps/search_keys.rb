require_relative "../../dot_env"

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
        class SearchKeys
          FIELDS = {
            "BRAVE_SEARCH_API_KEY" => "Brave Search API key",
            "GOOGLE_CSE_KEY" => "Google Programmable Search API key",
            "GOOGLE_CSE_CX" => "Google Programmable Search engine id (cx)"
          }.freeze

          # Google's `cx` names which engine to query, not a credential —
          # only the two API keys are secrets that never echo back.
          SECRET = %w[BRAVE_SEARCH_API_KEY GOOGLE_CSE_KEY].freeze

          def initialize(prompt:) = @prompt = prompt

          def title = "Search API keys"
          def default_yes? = true

          def call
            @prompt.say("DuckDuckGo's free API is already active and needs no key, but only resolves a " \
                        "specific brand/product name — set either Brave's key, or both Google fields, for " \
                        "real open-ended search. Neither key is echoed back; Enter keeps whatever's " \
                        "already set.")
            assignments = collect
            return @prompt.say("Left search API keys unchanged.") if assignments.empty?

            path = DotEnv.update!(assignments)
            @prompt.say("Saved #{assignments.keys.join(', ')} to #{path} (chmod 600).")
          end

          private

          def collect
            FIELDS.each_with_object({}) do |(var, label), assignments|
              hint = ENV.fetch(var, nil).to_s.empty? ? "not set" : "already set"
              answer = SECRET.include?(var) ? @prompt.ask_secret(label, hint: hint) : @prompt.ask(label, hint: hint)
              assignments[var] = answer if answer
            end
          end
        end
      end
    end
  end
end
