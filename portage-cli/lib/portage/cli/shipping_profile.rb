require "portage/ucp"

module Portage
  module Cli
    # Reads a shopper's default shipping address from the process environment
    # — the same "your own credentials live in env, not on the command line"
    # posture Resolver.env_for already uses for adapter credentials, applied
    # here to a buyer-profile concern instead of a platform-credential one
    # (so it lives in portage-cli, not Portage::Ucp::Resolver).
    module ShippingProfile
      ENV_VARS = {
        street_address: "PORTAGE_SHIP_STREET", extended_address: "PORTAGE_SHIP_EXTENDED",
        address_locality: "PORTAGE_SHIP_CITY", address_region: "PORTAGE_SHIP_REGION",
        address_country: "PORTAGE_SHIP_COUNTRY", postal_code: "PORTAGE_SHIP_POSTAL_CODE",
        first_name: "PORTAGE_SHIP_FIRST_NAME", last_name: "PORTAGE_SHIP_LAST_NAME",
        phone_number: "PORTAGE_SHIP_PHONE"
      }.freeze

      REQUIRED = %i[street_address address_locality address_country postal_code].freeze

      # @return [Portage::Ucp::PostalAddress, nil] nil unless every required
      #   field is set — a partial profile isn't enough to submit, and this
      #   module never guesses at a missing field.
      def self.from_env
        attrs = ENV_VARS.filter_map { |key, var| [key, ENV.fetch(var, nil)] if ENV.key?(var) }.to_h
        return nil unless REQUIRED.all? { |key| attrs.key?(key) }

        Portage::Ucp::PostalAddress.new(**attrs)
      end
    end
  end
end
