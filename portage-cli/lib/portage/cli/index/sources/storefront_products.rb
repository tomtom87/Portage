require "net/http"
require "uri"

require_relative "../../user_agent"
require_relative "../../classifier"
require_relative "../../handoff_only"
require_relative "../store"
require_relative "storefront_products/mapper"
require_relative "storefront_products/robots"
require_relative "storefront_products/pages"

module Portage
  module Cli
    module Index
      module Sources
        # A store's own public catalogue, read from Shopify's `/products.json`
        # (docs/plans/local-catalogue.md Phase 2), for origins already in
        # the index. Off by default: it runs only from `portage index build
        # --sources storefront_products` or `portage index add URL --crawl`,
        # never from `find` or `buy`.
        #
        # Guardrails: a hand-off-only host (HandoffOnly, checked live) and a
        # robots.txt Disallow get no products.json request at all; pages are
        # MAX_PAGES x 250 at most, PAUSE seconds apart; a 429 waits out its
        # Retry-After once and a second 429 stops that store; a 404, a
        # redirect, an empty page 1, or anything that isn't products JSON
        # (a bot wall) skips the store. Every outcome is noted on the store
        # row as `crawl` ({status, reason, pages, products, at}).
        #
        # Yields Mapper sightings (no price, no availability) plus one store
        # sighting per origin carrying `store_fields:` (the crawl note, and
        # platform "shopify" when products.json answered); Index::Builder
        # writes both.
        class StorefrontProducts
          MAX_PAGES = 20
          MAX_STORES = 25
          PER_PAGE = 250

          # The one platform seam: WooCommerce's Store API can join here.
          # nil platform means "not known yet", worth a try.
          def self.endpoint_for(origin, platform)
            "#{origin}/products.json" if platform.nil? || platform == "shopify"
          end

          # The guardrails, plus test seams for sleeping and the clock.
          def initialize(stores: Store.new, handoff_only: HandoffOnly.new, max_pages: MAX_PAGES,
                         max_stores: MAX_STORES, per_page: PER_PAGE, sleeper: Kernel.method(:sleep), now: Time.now)
            @stores = stores
            @handoff_only = handoff_only
            @max_pages = max_pages
            @max_stores = max_stores
            @per_page = per_page
            @sleeper = sleeper
            @now = now
          end

          def name = "storefront_products"

          def description
            "Each indexed store's own /products.json (Shopify), up to #{MAX_PAGES} pages a store and " \
              "#{MAX_STORES} stores a run, least recently crawled first. Off by default — opt in with " \
              "--sources storefront_products or `index add URL --crawl`."
          end

          def source_path = nil

          # `**` accepts (and ignores) the shared Source#candidates(queries:)
          # interface.
          def candidates(**)
            eligible = @stores.all.select do |entry|
              self.class.endpoint_for(entry["origin"], entry["platform"]) && !handoff_only?(entry["origin"])
            end
            eligible.sort_by { |entry| entry.dig("crawl", "at").to_i }.first(@max_stores)
                    .flat_map { |entry| crawl(entry["origin"], platform: entry["platform"]) }
          end

          # @return [Array<Hash>] product sightings, then the store sighting.
          def crawl(origin, platform: nil)
            endpoint = self.class.endpoint_for(origin, platform)
            robots = robots_for(origin, endpoint)
            return [store_sighting(origin, note("skipped", robots, 0, 0))] if robots.is_a?(String)

            sightings = []
            classify = memoized_classifier
            status, reason, pages = pages_for(endpoint, robots).each do |products|
              sightings.concat(products.map { |raw| Mapper.sighting(raw, origin: origin, classify: classify) })
            end
            sightings + [store_sighting(origin, note(status, reason, pages, sightings.length))]
          rescue StandardError => e
            [store_sighting(origin, note("skipped", "error: #{e.class}", 0, 0))]
          end

          private

          def pages_for(endpoint, robots)
            Pages.new(endpoint, per_page: @per_page, max_pages: @max_pages, sleeper: @sleeper,
                                allowed: ->(path) { robots.allowed?(path, agent: UserAgent.value) })
          end

          # The store's robots.txt rules, or why the crawl stops before
          # any request (no endpoint, hand-off only) or before any
          # products.json request (robots.txt unreachable). Pages checks
          # the rules against every page URL it would request.
          # RFC 9309: a 4xx robots.txt means no rules; a 5xx or no answer
          # at all means stay out.
          # @return [Robots, String]
          def robots_for(origin, endpoint)
            return "unsupported_platform" unless endpoint
            return "handoff_only" if handoff_only?(origin)

            response = Pages.get("#{origin}/robots.txt", accept: "text/plain")
            return Robots.new(nil) if response.code.start_with?("4")
            return "redirect" if response.is_a?(Net::HTTPRedirection)
            return "robots_unreachable" unless response.is_a?(Net::HTTPSuccess)

            Robots.new(response.body.to_s.dup.force_encoding(Encoding::UTF_8))
          rescue StandardError
            "robots_unreachable"
          end

          # Product types and tags repeat across a catalogue, and Classifier
          # re-reads its YAML on every call.
          def memoized_classifier
            memo = {}
            ->(text) { memo[text] ||= Classifier.categories_for(text) }
          end

          def handoff_only?(origin)
            @handoff_only.host?(URI.parse(origin.to_s).host)
          rescue URI::InvalidURIError
            true
          end

          def note(status, reason, pages, products)
            { "status" => status, "reason" => reason, "pages" => pages, "products" => products, "at" => @now.to_i }
          end

          def store_sighting(origin, crawl)
            fields = { crawl: crawl }
            fields[:platform] = "shopify" unless crawl["status"] == "skipped"
            { origin: origin, url: nil, title: nil, brand: nil, gtin: nil, store_fields: fields }
          end
        end
      end
    end
  end
end
