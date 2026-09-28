require "uri"
require "timeout"
require "portage/ucp/client"

require_relative "agent_profile_url"
require_relative "buyer_context"
require_relative "catalog_products"
require_relative "user_agent"

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
      # DuckDuckGo/Brave/Google CSE at the top: your own allowlist/keyed web
      # search first, the global catalog last, since it only ever names
      # Shopify merchants.
      def self.default
        [ShopifyCatalog.new]
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
    end
  end
end
