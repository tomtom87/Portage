require_relative "../../shipping_profile"
require_relative "../../dot_env"

module Portage
  module Cli
    class SetupWizard
      module Steps
        # Step 1 (docs/plans/buy-skill-and-local-browser.md Phase 4):
        # PORTAGE_SHIP_*, written to ~/.portage/.env. Without at least the
        # required fields, `portage buy` sends no shipping destination to
        # your own store's checkout, and without the country a native UCP
        # store prices in no market and can report in-stock items as out of
        # stock (see Doctor#shipping_finding, which this step exists to
        # resolve).
        class Shipping
          LABELS = {
            street_address: "Street address", extended_address: "Apt/suite (optional)",
            address_locality: "City", address_region: "State/region (optional)",
            address_country: "Country (ISO 3166-1 alpha-2, e.g. US, GB)", postal_code: "Postal code",
            first_name: "First name (optional)", last_name: "Last name (optional)",
            phone_number: "Phone (optional)"
          }.freeze

          def initialize(prompt:) = @prompt = prompt

          def title = "Shipping address"
          def default_yes? = true

          def call
            @prompt.say("Enter keeps whatever's already set for a field.")
            assignments = collect
            return @prompt.say("Left shipping address unchanged.") if assignments.empty?

            path = DotEnv.update!(assignments)
            @prompt.say("Saved #{assignments.keys.join(', ')} to #{path} (chmod 600).")
          end

          private

          def collect
            ShippingProfile::ENV_VARS.each_with_object({}) do |(key, var), assignments|
              hint = ENV.fetch(var, nil).to_s.empty? ? "not set" : "already set"
              answer = @prompt.ask(LABELS.fetch(key), hint: hint)
              assignments[var] = answer if answer
            end
          end
        end
      end
    end
  end
end
