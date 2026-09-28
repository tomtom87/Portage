module Portage
  module Cli
    class SetupWizard
      module Steps
        # Step 6 (docs/plans/buy-skill-and-local-browser.md Phase 4):
        # spending policy caps (Portage::Ucp::PolicyGuard), via `portage
        # policy set` — reused, not reimplemented, so the actual cap/
        # allowlist logic (Cli.set_policy_cap/set_policy_allowlist) has
        # exactly one place it lives.
        class Policy
          def initialize(prompt:) = @prompt = prompt

          def title = "Spending policy caps"
          def default_yes? = true

          def call
            @prompt.say("Checked before every `portage buy --yes` checkout completes. Enter skips a " \
                        "question you don't want to answer right now — nothing here is required.")
            args = cap_args + allowlist_args
            return @prompt.say("No policy changes made.") if args.empty?

            Portage::Cli.send(:run_policy_set, args)
          end

          private

          def cap_args
            major = @prompt.ask("Per-transaction spending cap", hint: "major units, e.g. 200 for $200; Enter to skip")
            return [] unless major

            parsed = Float(major, exception: false)
            return not_a_number unless parsed&.positive?

            currency = @prompt.ask("Currency for that cap", hint: "e.g. USD")
            return no_currency if currency.nil?

            # Cli.to_minor_units is private — reused via `send` rather than
            # a second implementation of major-to-minor-units conversion.
            ["--per-transaction-cap", Portage::Cli.send(:to_minor_units, parsed).to_s, "--currency", currency]
          end

          def not_a_number
            @prompt.say("Not a number — cap not set.")
            []
          end

          def no_currency
            @prompt.say("No currency given — cap not set.")
            []
          end

          def allowlist_args
            hosts = @prompt.ask("Merchant allowlist hosts to add", hint: "comma-separated, Enter to skip")
            Array(hosts&.split(",")).map(&:strip).reject(&:empty?).flat_map { |host| ["--allow", host] }
          end
        end
      end
    end
  end
end
