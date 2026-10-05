require_relative "../../shipping_profile"
require_relative "env_keys_step"

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
        class Shipping < EnvKeysStep
          LABELS = {
            street_address: "Street address", extended_address: "Apt/suite (optional)",
            address_locality: "City", address_region: "State/region (optional)",
            address_country: "Country (ISO 3166-1 alpha-2, e.g. US, GB)", postal_code: "Postal code",
            first_name: "First name (optional)", last_name: "Last name (optional)",
            phone_number: "Phone (optional)"
          }.freeze

          FIELDS = ShippingProfile::ENV_VARS.to_h { |key, var| [var, LABELS.fetch(key)] }.freeze

          def title = "Shipping address"
          def default_yes? = true

          private

          def intro = "Enter keeps whatever's already set for a field."
          def unchanged_message = "Left shipping address unchanged."
        end
      end
    end
  end
end
