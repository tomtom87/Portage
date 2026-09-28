require "uri"
require "timeout"
require "portage/ucp/client"

require_relative "agent_profile_url"
require_relative "buyer_context"
require_relative "catalog_products"
require_relative "user_agent"
require_relative "search_backends"
require_relative "handoff_only"

module Portage
  module Cli
    # A second kind of `find` backend, next to SearchBackends: those return
    # bare candidate URLs that still need a `/.well-known/ucp` probe before
    # anything is known about what they stock; an OfferSource answers offers
    # directly, in the same shape Find itself builds
    # (Find#offer — store:/source:/checkout:/product_id:/title:/amount:/
    # currency:/url:), with no probe of its own. Find#call merges the two
    # before Decisions.rank.
    module OfferSources
      # Shopify's catalog needs no key and is always on; the five retailer
      # APIs below (Phase 7, docs/plans/buy-skill-and-local-browser.md) are
      # each opt-in — `#available?` is false until the user sets that
      # source's own key(s) via `portage setup`'s wizard or ~/.portage/.env
      # directly, so a fresh install's `find` behaves exactly as before
      # this phase existed.
      def self.default
        [ShopifyCatalog.new, *retailers.select(&:available?)]
      end

      def self.retailers
        [WalmartAffiliate.new, EbayBrowse.new, BestBuyProducts.new, EtsyListings.new, AmazonCreators.new]
      end

      # Every retailer offer source below ends in hand-off — none of them
      # is native UCP, none has a checkout Buy can drive, and walmart.com/
      # ebay.com/bestbuy.com have no adapter this gem ships at all. Buy#
      # handoff_only? checks this alongside HandoffOnly's own (user-
      # editable, Amazon-only) list so a `portage buy` against one of
      # these offers' `store` never fetches the page first — that would
      # just be scraping. Not user-editable, unlike HandoffOnly's list:
      # this isn't a policy choice, it's a direct consequence of shipping
      # a source with zero purchase automation. etsy.com is deliberately
      # left out of this list — portage-ucp-etsy is a *seller*-side
      # adapter, so Buy decides that one itself (see Buy#etsy_buyer_host?)
      # rather than this module overriding a shop owner's own store.
      RETAIL_HANDOFF_HOSTS = %w[walmart.com ebay.com bestbuy.com].freeze

      def self.retail_handoff_host?(host) = HandoffOnly.matches_any?(host, RETAIL_HANDOFF_HOSTS)

      # Shared by every retailer source below: an offer's `store` is the
      # origin of the item URL the API itself returned, same idea as
      # ShopifyCatalog#origin_of — kept as one module method instead of
      # four copies.
      def self.origin_of(url)
        uri = URI.parse(url.to_s)
        return nil unless uri.host && uri.scheme.to_s.start_with?("http")

        port = uri.port == uri.default_port ? "" : ":#{uri.port}"
        "#{uri.scheme}://#{uri.host}#{port}"
      rescue URI::InvalidURIError
        nil
      end

      # Shopify's global catalog search (`catalog.shopify.com/api/ucp/mcp`)
      # — answers `search_catalog` anonymously with a correct agent profile,
      # across every merchant on the platform, not just the ones a web
      # search or `stores.yml` named (docs/ucp-tool-gating-investigation.md).
      #
      # Every result's `store` is the *merchant's* origin, not
      # catalog.shopify.com — buying it then goes through the ordinary
      # native-UCP path against that origin, the same as any other offer
      # Find hands to `portage buy`. That means this source counts toward
      # nothing in Find::MAX_PROBES: it never touches a merchant's own
      # `/.well-known/ucp`, and the merchant only gets probed if the caller
      # goes on to buy from it.
      #
      # IDs (live check 2026-09-28, query "hiking boots", GB/GBP): a
      # product's own `id` is a global catalog id (`gid://shopify/p/…`) the
      # merchant itself won't recognise, but each of its `variants[].id` is
      # the merchant's real `gid://shopify/ProductVariant/…`, and
      # `variants[].url` sits on the merchant's own domain. So the offer
      # uses the first variant's id as `product_id` and its URL's origin as
      # `store` — Buy#select_product/#line_item_id_of know how to check that
      # variant out directly, no title re-search needed.
      class ShopifyCatalog
        ENDPOINT = "https://catalog.shopify.com/api/ucp/mcp".freeze
        TIMEOUT = 5

        # @param agent_profile [String, nil] nil (the default) resolves
        #   PORTAGE_AGENT_PROFILE / AgentProfileUrl::DEFAULT at call time,
        #   the same as every other caller into a real UCP server.
        def initialize(endpoint: ENDPOINT, agent_profile: nil)
          @endpoint = endpoint
          @agent_profile = agent_profile
        end

        def name = "shopify_catalog"

        # One backend being down, rate-limited, or misconfigured shouldn't
        # take the whole `find` with it — same posture as
        # SearchBackends#urls_from. `Timeout.timeout` bounds it the same
        # way, since neither Session nor its HTTP transport takes a
        # deadline of their own.
        # @return [Array<Hash>] the Find#offer shape, one per merchant
        #   variant the catalog returned; empty on any failure.
        def offers(query, limit: 10, context: nil)
          products = Timeout.timeout(TIMEOUT) do
            CatalogProducts.from(
              session.search_catalog(query: query, limit: limit, context: context || BuyerContext.from_env,
                                     meta: agent_meta)
            )
          end
          products.filter_map { |product| offer(product) }
        rescue StandardError
          []
        end

        private

        def session
          @session ||= Portage::Ucp::Client.connect(url: @endpoint, headers: UserAgent.headers)
        end

        def agent_meta
          { agent_profile: @agent_profile || AgentProfileUrl.resolve }
        end

        def offer(product)
          variant = Array(product["variants"]).first
          origin = variant && origin_of(variant["url"])
          return nil unless origin

          amount, currency = price_of(product)
          { store: origin, source: name, checkout: nil, product_id: variant["id"], title: product["title"],
            amount: amount, currency: currency, url: variant["url"] }
        end

        def origin_of(url)
          uri = URI.parse(url.to_s)
          return nil unless uri.host && uri.scheme.to_s.start_with?("http")

          port = uri.port == uri.default_port ? "" : ":#{uri.port}"
          "#{uri.scheme}://#{uri.host}#{port}"
        rescue URI::InvalidURIError
          nil
        end

        # Same wire shape as Find#price_of — a `price_range.min` Money
        # object, wire-hash-keyed same as every result that's passed through
        # Dispatcher#wrap's `to_wire_h`.
        def price_of(product)
          range = product["price_range"]
          return [nil, nil] unless range.is_a?(Hash) && range["min"].is_a?(Hash)

          [range["min"]["amount"], range["min"]["currency"]]
        end
      end

      # --- Phase 7: official buyer-side retailer APIs, hand-off only -----
      #
      # None of these gets anywhere near a cart or a checkout — every offer
      # they return has `checkout: false`, and its `store` is one of
      # RETAIL_HANDOFF_HOSTS (or amazon.*, already covered by HandoffOnly),
      # so `portage buy` against it always lands on the existing
      # hand-off-only report rather than trying to drive the site. None of
      # them writes into the local index either: they're not in
      # Index::Sources::DEFAULT_NAMES (or anywhere else `portage index
      # build` looks), which is how "nothing from these goes into
      # products.json/stores.json" is enforced — there's simply no code
      # path that would put one there.
      #
      # Every one of them is opt-in (`#available?` gated on its own env
      # var(s), same posture as SearchBackends::Brave/GoogleCse), uses
      # Portage::Ucp::Support::Connection — via SearchBackends.get_json,
      # never raw Net::HTTP — with the same 5s open/read timeout every
      # other search-shaped call in this gem gets, and swallows its own
      # failures (no key, timeout, non-2xx, unparseable JSON) exactly like
      # ShopifyCatalog above, so one retailer being down or misconfigured
      # never takes `find` down with it.

      # Walmart's affiliate/product-search API (`api.walmartlabs.com`) —
      # the shape documented for the "Walmart Open API"/"Walmart Affiliate
      # API" family. **Not live-checked** (docs/plans/
      # buy-skill-and-local-browser.md Phase 7 progress log): this session
      # had no API key to verify the endpoint or response shape against;
      # confirm both against Walmart's current affiliate program docs
      # before relying on this in production.
      class WalmartAffiliate
        ENDPOINT = "https://api.walmartlabs.com/v1/search".freeze
        TIMEOUT = 5
        STORE = "https://www.walmart.com".freeze

        def initialize(api_key: ENV.fetch("WALMART_AFFILIATE_API_KEY", nil))
          @api_key = api_key
        end

        def name = "walmart_affiliate"
        def available? = !@api_key.to_s.empty?

        def offers(query, limit: 10, **)
          return [] unless available?

          data = Timeout.timeout(TIMEOUT) do
            SearchBackends.get_json(URI.parse(ENDPOINT), params: { query: query, apiKey: @api_key, format: "json" })
          end
          Array(data && data["items"]).first(limit).filter_map { |item| offer(item) }
        rescue StandardError
          []
        end

        private

        def offer(item)
          url = item["productUrl"]
          return nil if url.to_s.empty?

          { store: STORE, source: name, checkout: false, product_id: item["itemId"]&.to_s, title: item["name"],
            amount: minor_units(item["salePrice"]), currency: "USD", url: url }
        end

        def minor_units(price)
          price.is_a?(Numeric) ? (price * 100).round : nil
        end
      end

      # eBay's Browse API, Buy It Now only (`filter=buyingOptions:
      # {FIXED_PRICE}`, checked again here in code since a caller shouldn't
      # have to trust a query-string filter alone) — deliberately never
      # touches eBay's Order API or its guest checkout, which takes raw
      # card data. `EBAY_BROWSE_ACCESS_TOKEN` is an Application Access
      # Token the user generates themselves (eBay Developer Program,
      # client-credentials grant) — it expires roughly every two hours, so
      # this class doesn't try to refresh it; a stale token just makes
      # `available?` look true but every call fail closed (swallowed, same
      # as any other failure).
      class EbayBrowse
        ENDPOINT = "https://api.ebay.com/buy/browse/v1/item_summary/search".freeze
        TIMEOUT = 5
        FIXED_PRICE = "FIXED_PRICE".freeze

        def initialize(access_token: ENV.fetch("EBAY_BROWSE_ACCESS_TOKEN", nil),
                       marketplace: ENV.fetch("EBAY_MARKETPLACE_ID", "EBAY_US"))
          @access_token = access_token
          @marketplace = marketplace
        end

        def name = "ebay_browse"
        def available? = !@access_token.to_s.empty?

        def offers(query, limit: 10, **)
          return [] unless available?

          data = Timeout.timeout(TIMEOUT) do
            SearchBackends.get_json(
              URI.parse(ENDPOINT),
              params: { q: query, limit: limit, filter: "buyingOptions:{#{FIXED_PRICE}}" },
              headers: { "Authorization" => "Bearer #{@access_token}", "X-EBAY-C-MARKETPLACE-ID" => @marketplace }
            )
          end
          Array(data && data["itemSummaries"]).filter_map { |item| offer(item) }
        rescue StandardError
          []
        end

        private

        def offer(item)
          return nil unless Array(item["buyingOptions"]).include?(FIXED_PRICE)

          url = item["itemWebUrl"]
          origin = url && OfferSources.origin_of(url)
          return nil unless origin

          price = item["price"] || {}
          { store: origin, source: name, checkout: false, product_id: item["itemId"], title: item["title"],
            amount: minor_units(price["value"]), currency: price["currency"], url: url }
        end

        def minor_units(value)
          Float(value, exception: false)&.then { |f| (f * 100).round }
        end
      end

      # Best Buy Products API (`api.bestbuy.com`) — `show=` trims the
      # response to just what an offer needs.
      class BestBuyProducts
        ENDPOINT = "https://api.bestbuy.com/v1/products".freeze
        TIMEOUT = 5
        STORE = "https://www.bestbuy.com".freeze

        def initialize(api_key: ENV.fetch("BESTBUY_API_KEY", nil))
          @api_key = api_key
        end

        def name = "bestbuy_products"
        def available? = !@api_key.to_s.empty?

        def offers(query, limit: 10, **)
          return [] unless available?

          uri = URI.parse("#{ENDPOINT}(search=#{URI.encode_www_form_component(query)})")
          data = Timeout.timeout(TIMEOUT) do
            SearchBackends.get_json(uri, params: { apiKey: @api_key, format: "json", pageSize: limit,
                                                   show: "sku,name,salePrice,url" })
          end
          Array(data && data["products"]).first(limit).filter_map { |item| offer(item) }
        rescue StandardError
          []
        end

        private

        def offer(item)
          url = item["url"]
          return nil if url.to_s.empty?

          { store: STORE, source: name, checkout: false, product_id: item["sku"]&.to_s, title: item["name"],
            amount: minor_units(item["salePrice"]), currency: "USD", url: url }
        end

        def minor_units(price)
          price.is_a?(Numeric) ? (price * 100).round : nil
        end
      end

      # Etsy Open API v3's `findAllListingsActive` — buyer-side, public
      # listing search, needs only an API key (`x-api-key`), no OAuth. This
      # is a different surface from `portage-ucp-etsy`, which is the
      # *seller*-side adapter a shop owner's own ETSY_* credentials drive
      # (see Buy#etsy_buyer_host? for how the two stay out of each other's
      # way at buy time).
      class EtsyListings
        ENDPOINT = "https://openapi.etsy.com/v3/application/listings/active".freeze
        TIMEOUT = 5

        def initialize(api_key: ENV.fetch("ETSY_LISTINGS_API_KEY", nil))
          @api_key = api_key
        end

        def name = "etsy_listings"
        def available? = !@api_key.to_s.empty?

        def offers(query, limit: 10, **)
          return [] unless available?

          data = Timeout.timeout(TIMEOUT) do
            SearchBackends.get_json(URI.parse(ENDPOINT), params: { keywords: query, limit: limit },
                                                         headers: { "x-api-key" => @api_key })
          end
          Array(data && data["results"]).first(limit).filter_map { |item| offer(item) }
        rescue StandardError
          []
        end

        private

        def offer(item)
          url = item["url"] || listing_url(item["listing_id"])
          return nil if url.to_s.empty?

          amount, currency = price_of(item["price"])
          { store: "https://www.etsy.com", source: name, checkout: false, product_id: item["listing_id"]&.to_s,
            title: item["title"], amount: amount, currency: currency, url: url }
        end

        def listing_url(id) = id && "https://www.etsy.com/listing/#{id}"

        # Etsy's Money resource: minor units already, via amount/divisor
        # (amount: 1999, divisor: 100 == $19.99) rather than a decimal.
        def price_of(price)
          return [nil, nil] unless price.is_a?(Hash) && price["amount"].is_a?(Numeric)

          [price["amount"], price["currency_code"]]
        end
      end

      # Amazon Creators API — Amazon's Product Advertising API (PA-API 5)
      # is deprecated (retiring 2026-05-15) and no longer onboards new
      # integrations; Creators API is its OAuth2 successor
      # (affiliate-program.amazon.com/creatorsapi/docs, checked
      # 2026-09-28). `AMAZON_CREATORS_ACCESS_TOKEN` is a bearer token the
      # user obtains through that OAuth flow themselves — this class
      # doesn't implement the OAuth dance or token refresh, only the
      # search call, the same "bring your own token" posture as
      # EbayBrowse's Application Access Token above.
      #
      # **Not live-checked, best-effort schema** (docs/plans/
      # buy-skill-and-local-browser.md Phase 7 progress log): Creators
      # API's full request/response reference sits behind an approved
      # Associates account this session doesn't have. The item shape below
      # follows the long-stable PA-API `SearchItems`/`GetItems` resource
      # names (`ASIN`, `DetailPageURL`, `Offers.Listings[0].Price`), which
      # Amazon's own docs describe Creators API as continuing — confirm
      # against the real docs before enabling this in production. Amazon
      # is already Tier C (`HandoffOnly.amazon?`): every offer this
      # returns goes through Buy's existing hand-off-only path the moment
      # anyone tries to buy it, the same as an Amazon URL found any other
      # way, so a schema mismatch here only means a missed offer in
      # `find`, never a purchase-automation risk — a non-matching item is
      # dropped by `#offer`'s own nil guard, not raised.
      class AmazonCreators
        ENDPOINT = "https://creators-api.amazon.com/searchItems".freeze
        TIMEOUT = 5

        def initialize(access_token: ENV.fetch("AMAZON_CREATORS_ACCESS_TOKEN", nil),
                       marketplace: ENV.fetch("AMAZON_CREATORS_MARKETPLACE", "www.amazon.com"))
          @access_token = access_token
          @marketplace = marketplace
        end

        def name = "amazon_creators"
        def available? = !@access_token.to_s.empty?

        def offers(query, limit: 10, **)
          return [] unless available?

          data = Timeout.timeout(TIMEOUT) do
            SearchBackends.get_json(URI.parse(ENDPOINT), params: { keywords: query, marketplace: @marketplace },
                                                         headers: { "Authorization" => "Bearer #{@access_token}",
                                                                    "Accept" => "application/json" })
          end
          Array(data && (data["items"] || data["Items"])).first(limit).filter_map { |item| offer(item) }
        rescue StandardError
          []
        end

        private

        def offer(item)
          url = item["detailPageUrl"] || item["DetailPageURL"]
          asin = item["asin"] || item["ASIN"]
          return nil if url.to_s.empty? || asin.to_s.empty?

          amount, currency = price_of(item)
          { store: "https://#{@marketplace}", source: name, checkout: false, product_id: asin,
            title: title_of(item), amount: amount, currency: currency, url: url }
        end

        def title_of(item) = item["title"] || item.dig("ItemInfo", "Title", "DisplayValue")

        def price_of(item)
          price = price_field(item)
          return [nil, nil] unless price.is_a?(Hash)

          amount = price["amount"] || price["Amount"]
          [amount.is_a?(Numeric) ? (amount * 100).round : nil, price["currency"] || price["Currency"]]
        end

        def price_field(item)
          listing = item.dig("offers", "listings", 0) || item.dig("Offers", "Listings", 0)
          return nil unless listing.is_a?(Hash)

          listing["price"] || listing["Price"]
        end
      end
    end
  end
end
