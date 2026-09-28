module Portage
  module Cli
    class SetupWizard
      module Steps
        # Step 4 (docs/plans/buy-skill-and-local-browser.md Phase 4):
        # `portage browser import` (Phase 3, Tier A). Opt-in and off by
        # default here, same as the command itself — this step only asks
        # which browser, then hands off to Cli.run_browser_import so the
        # command's own read -> reduce -> probe -> show -> confirm flow
        # (BrowserImport::Confirm) runs unchanged, prompt and all.
        class BrowserImport
          def initialize(prompt:) = @prompt = prompt

          def title = "Browser import"
          def default_yes? = false

          def call
            @prompt.say("Local-only: reduces your browser's bookmarks/history to shop domains, probes each " \
                        "unknown one for /.well-known/ucp, and shows you the list before saving anything to " \
                        "your local index. Never reads passwords, cookies or saved-card autofill.")
            browser = @prompt.ask("Which browser", hint: "chrome/edge/brave/arc/firefox/safari — Enter to autodetect")
            args = browser ? ["--browser", browser] : []
            Portage::Cli.send(:run_browser_import, args)
          end
        end
      end
    end
  end
end
