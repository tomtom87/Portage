require_relative "shipping_profile"

module Portage
  module Cli
    # docs/plans/webmcp-universal-outbound.md Phase 3 — the shopper-approved
    # data autofill is ever allowed to type into a store's checkout page:
    # contact email and the PORTAGE_SHIP_* shipping address
    # (Portage::Cli::ShippingProfile), each named by the WHATWG
    # autocomplete token (https://html.spec.whatwg.org/#autofill) a standards
    # -following checkout page's own field should carry, which is what
    # Portage::Ucp::WebMcp::Autofill/assets/autofill.js match against.
    #
    # Deliberately the only place in this gem that reads PORTAGE_SHIP_EMAIL
    # — a contact email is a WebMCP-autofill-only concern (native/adapter
    # checkouts take it as part of `context`/the adapter's own contract, not
    # a standalone shipping field), so it doesn't belong on ShippingProfile
    # or BuyerContext, both of which are shared with paths that never touch
    # a browser.
    module WebmcpAutofillFields
      EMAIL_ENV_VAR = "PORTAGE_SHIP_EMAIL".freeze

      # ShippingProfile attribute => the autocomplete token
      # assets/autofill.js looks for on the checkout page.
      TOKENS = {
        first_name: "shipping given-name",
        last_name: "shipping family-name",
        street_address: "shipping address-line1",
        extended_address: "shipping address-line2",
        address_locality: "shipping address-level2",
        address_region: "shipping address-level1",
        postal_code: "shipping postal-code",
        address_country: "shipping country",
        phone_number: "shipping tel"
      }.freeze

      module_function

      # @param address [Portage::Ucp::PostalAddress, nil] nil (the default)
      #   reads PORTAGE_SHIP_* fresh; injectable so a spec doesn't need real
      #   env vars set.
      # @return [Hash{String=>String}] autocomplete token => value. Empty
      #   when neither an email nor a usable shipping address is
      #   configured — #call in Buy treats that as nothing to autofill,
      #   same as no PORTAGE_SHIP_* today.
      def build(address: Portage::Cli::ShippingProfile.from_env)
        fields = {}
        email = ENV.fetch(EMAIL_ENV_VAR, nil)
        fields["email"] = email unless email.to_s.strip.empty?

        return fields unless address

        TOKENS.each do |attribute, token|
          value = address.public_send(attribute)
          fields[token] = value unless value.to_s.strip.empty?
        end
        fields
      end
    end
  end
end
