require_relative "../../config"
require_relative "../../checkout_handoff"

module Portage
  module Cli
    class SetupWizard
      module Steps
        # Step 7 (docs/plans/buy-skill-and-local-browser.md Phase 4):
        # hand-off target. Phase 5 (PORTAGE_HANDOFF_TARGET, hand-off-only
        # hosts) isn't built yet, so this step doesn't invent that config —
        # it configures the one hand-off setting that already exists today,
        # CheckoutHandoff's auto-open toggle
        # (PORTAGE_AUTO_OPEN_CHECKOUT/config.json's "auto_open_checkout"),
        # and explains what's still to come so re-running the wizard after
        # Phase 5 lands is the obvious next step, not a surprise. Keeping
        # this its own step (rather than folding it into another one) is
        # the seam Phase 5 extends: `PORTAGE_HANDOFF_TARGET`/hand-off-only
        # host prompts land here.
        class Handoff
          def initialize(prompt:) = @prompt = prompt

          def title = "Hand-off"
          def default_yes? = true

          def call
            @prompt.say("When a buy hands off — no payment token, an escalation, or a dead end — Portage " \
                        "can open the checkout URL in your default browser so you finish it there: your " \
                        "login, region, saved addresses and cards all apply. A fuller choice of hand-off " \
                        "targets (a driven Portage browser profile, an approved external agent) and the " \
                        "hand-off-only host list for sites like Amazon are a later phase, not built yet.")
            toggle_auto_open
          end

          private

          def toggle_auto_open
            current = CheckoutHandoff.new.auto_open?
            answer = @prompt.confirm("Auto-open the checkout URL in your browser on hand-off?", default: current)
            return @prompt.say("Left unchanged.") if answer == current

            Config.load.set("auto_open_checkout", answer)
            @prompt.say("Saved to ~/.portage/config.json.")
          end
        end
      end
    end
  end
end
