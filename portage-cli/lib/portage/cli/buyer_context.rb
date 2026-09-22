module Portage
  module Cli
    # Builds the UCP `context` object — the buyer locale hints a real store
    # resolves a market from — out of the same `PORTAGE_SHIP_*` environment
    # Portage::Cli::ShippingProfile reads, plus two of its own.
    #
    # Separate from ShippingProfile rather than a method on it because the two
    # have opposite completeness rules. A shipping *address* is all-or-nothing:
    # ShippingProfile returns nil unless every required field is set, since a
    # half-filled address can't be submitted and this CLI never guesses at the
    # missing half. A context is explicitly partial by design ("provisional
    # context hints ... unsupported hints may be ignored without error"), and
    # a country alone is enough to resolve a market, so sending what's known
    # beats sending nothing.
    #
    # Sending nothing is the part that actually mattered: without a context,
    # a live Shopify store builds a cart scoped to no market, drops every line
    # item, and reports `merchandise_out_of_stock` for products its own
    # `search_catalog` just returned as available (confirmed live 2026-09-22,
    # see docs/ucp-tool-gating-investigation.md). So this returns `{}` rather
    # than nil when nothing is configured — a caller passes it through either
    # way, and `Transports::Http#with_context` omits an empty one from the
    # wire.
    module BuyerContext
      ENV_VARS = {
        address_country: "PORTAGE_SHIP_COUNTRY",
        address_region: "PORTAGE_SHIP_REGION",
        postal_code: "PORTAGE_SHIP_POSTAL_CODE",
        currency: "PORTAGE_CURRENCY",
        language: "PORTAGE_LANGUAGE"
      }.freeze

      # @return [Hash] context hints, empty when none are configured
      def self.from_env
        ENV_VARS.filter_map do |key, var|
          value = ENV.fetch(var, nil)
          [key, value] unless value.nil? || value.empty?
        end.to_h
      end
    end
  end
end
