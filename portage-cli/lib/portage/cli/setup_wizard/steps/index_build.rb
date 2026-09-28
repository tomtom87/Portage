module Portage
  module Cli
    class SetupWizard
      module Steps
        # Step 5 (docs/plans/buy-skill-and-local-browser.md Phase 4):
        # `portage index build` (Phases 2b-2c). Opt-in and off by default —
        # it's a live network sweep of Shopify's global catalog, one query
        # per taxonomy node, which is a lot to run unasked inside a wizard.
        # Delegates to Cli.run_index_build so the command's own sources,
        # probe cap and progress output are exactly what a direct
        # `portage index build` would give.
        class IndexBuild
          def initialize(prompt:) = @prompt = prompt

          def title = "Local store index"
          def default_yes? = false

          def call
            @prompt.say("Builds ~/.portage/index/{stores,products}.json — stores and products `find` can " \
                        "route by on top of stores.yml, the known-stores list this repo already fetches, " \
                        "and web search. Takes a little while: one query per product-category node against " \
                        "Shopify's catalog, verifying each new store with a single /.well-known/ucp probe.")
            return unless @prompt.confirm("Run `portage index build` now?", default: false)

            Portage::Cli.send(:run_index_build, [], refresh: false)
          end
        end
      end
    end
  end
end
