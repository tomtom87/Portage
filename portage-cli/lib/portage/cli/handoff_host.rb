require_relative "handoff_only"
require_relative "offer_sources"

module Portage
  module Cli
    # The one answer to "is this host hand-off only?" that both `buy` and
    # `check` give, so `portage check` never says something `portage buy`
    # wouldn't do. Three sources, in the order Buy has always consulted them:
    # the user's own list (HandoffOnly, Amazon by default), the built-in
    # retail hand-off hosts (Walmart, eBay, Best Buy), and Etsy for an
    # ordinary buyer — portage-ucp-etsy is a seller-side adapter, so a shop
    # owner with their own ETSY_* credentials set is not hand-off only.
    module HandoffHost
      def self.restricted?(host, handoff_only: HandoffOnly.new)
        return true if handoff_only.host?(host)
        return true if OfferSources.retail_handoff_host?(host)

        etsy_buyer_host?(host)
      end

      def self.etsy_buyer_host?(host)
        HandoffOnly.matches_any?(host, %w[etsy.com]) && !etsy_adapter_configured?
      end

      def self.etsy_adapter_configured?
        platform = Portage::Ucp::Resolver::PLATFORMS.find { |p| p.name == "Etsy" }
        return false unless platform

        Portage::Ucp::Resolver.missing_env(platform, Portage::Ucp::Resolver.env_for(platform)).empty?
      end
    end
  end
end
