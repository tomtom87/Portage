require_relative "../../agent_profile_url"
require_relative "../../dot_env"

module Portage
  module Cli
    class SetupWizard
      module Steps
        # Step 3 (docs/plans/buy-skill-and-local-browser.md Phase 4): the
        # agent profile every catalog/cart/checkout call carries
        # (PORTAGE_AGENT_PROFILE). Phase 1 already defaults it to this
        # repo's own published profile (AgentProfileUrl), so this step's
        # job is explaining that default and, opt-in, generating and
        # hosting your own — it never runs generation on its own.
        #
        # `portage generate agent-profile` itself is reused verbatim (via
        # Cli.run_generate_agent_profile), not reimplemented, so its own
        # output (where the files went, the "commit + purge the jsdelivr
        # cache" next step) stays the one place that message lives.
        class AgentProfile
          def initialize(prompt:) = @prompt = prompt

          def title = "Agent profile"
          def default_yes? = true

          def call
            @prompt.say("Falls back to this repo's own published profile right now:\n  " \
                        "#{AgentProfileUrl.resolve}\n" \
                        "That's fine to keep using. Generating your own is only worth it once you're " \
                        "hosting Portage for real, rather than trying it out.")
            return unless @prompt.confirm("Generate your own agent profile now?", default: false)

            generate
            host
          end

          private

          def generate
            out = @prompt.ask("Where to write the public profile", hint: "default: agent-profile.json") ||
                  "agent-profile.json"
            key_out = @prompt.ask("Where to write the private signing key", hint: "default: agent-profile.key.pem") ||
                      "agent-profile.key.pem"
            Portage::Cli.send(:run_generate_agent_profile, ["--out", out, "--key-out", key_out])
          end

          def host
            @prompt.say("Once it's hosted at a stable, public HTTPS URL (docs/agent-profile.md), point " \
                        "PORTAGE_AGENT_PROFILE at it.")
            url = @prompt.ask("URL you'll host it at", hint: "Enter to keep using the default for now")
            return unless url

            path = DotEnv.update!({ "PORTAGE_AGENT_PROFILE" => url })
            @prompt.say("Saved PORTAGE_AGENT_PROFILE to #{path} (chmod 600) — won't take effect until " \
                        "that URL actually serves the profile you just generated.")
          end
        end
      end
    end
  end
end
