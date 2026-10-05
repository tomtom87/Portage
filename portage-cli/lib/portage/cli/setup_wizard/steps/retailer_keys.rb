require_relative "env_keys_step"

module Portage
  module Cli
    class SetupWizard
      module Steps
        # Phase 7 (docs/plans/buy-skill-and-local-browser.md): the five
        # official retailer offer sources (OfferSources) are each opt-in —
        # this step is where their keys get written, same as SearchKeys
        # does for Brave/Google CSE. Every one of these still ends in
        # hand-off (see HandoffOnly / OfferSources.retail_handoff_host?):
        # setting a key here only makes `find` show more real offers, it
        # never lets `portage buy` complete a purchase at any of these
        # retailers.
        class RetailerKeys < EnvKeysStep
          FIELDS = {
            "WALMART_AFFILIATE_API_KEY" => "Walmart Affiliate API key",
            "EBAY_BROWSE_ACCESS_TOKEN" => "eBay Browse API access token (Buy It Now search only)",
            "BESTBUY_API_KEY" => "Best Buy Products API key",
            "ETSY_LISTINGS_API_KEY" => "Etsy Open API v3 key (buyer-side listing search)",
            "AMAZON_CREATORS_ACCESS_TOKEN" => "Amazon Creators API access token"
          }.freeze

          def title = "Retailer offer sources"
          def default_yes? = false

          private

          def intro
            "Optional: official buyer-side APIs for Walmart, eBay (Buy It Now only), Best " \
              "Buy, Etsy and Amazon. Each needs its own key from that retailer's developer " \
              "program — skip any you don't have. None of these ever completes a purchase: " \
              "every offer they return still ends in hand-off, same as Amazon today. Neither " \
              "key is echoed back; Enter keeps whatever's already set."
          end

          def unchanged_message = "Left retailer offer source keys unchanged."
          def secret?(_var) = true
        end
      end
    end
  end
end
