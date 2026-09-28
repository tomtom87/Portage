require "yaml"

require_relative "../../offer_sources"
require_relative "../../buyer_context"
require_relative "../../classifier"

module Portage
  module Cli
    module Index
      module Sources
        # Harvests merchant origins and product identities from Shopify's
        # global catalog — the same source `find` already uses live
        # (OfferSources::ShopifyCatalog), reused here rather than
        # duplicating its catalog-search/variant-URL logic (docs/plans/
        # buy-skill-and-local-browser.md Phase 2b: "reuse the Phase 1
        # ShopifyCatalog code rather than duplicating it").
        #
        # One query per top-level taxonomy node by default (21 nodes —
        # known-stores/categories.yml's own top level, its keyword rather
        # than its full "Parent > Child" name, so each query is a plain
        # shopping term like "electronics" or "apparel" instead of a taxon
        # label). Not per-country: BuyerContext.from_env already applies
        # whatever PORTAGE_SHIP_COUNTRY/PORTAGE_CURRENCY the user has set,
        # same as every other catalog call this CLI makes, and fanning the
        # same 21 queries out across every market on every `index build`
        # would turn a several-second command into a slow one for no
        # benefit a single run doesn't already get from the user's own
        # locale (Open question 1, resolved 2026-09-28).
        class ShopifyCatalog
          PER_QUERY_LIMIT = 20

          def initialize(catalog: OfferSources::ShopifyCatalog.new, categories_path: Classifier::KNOWN_PATH)
            @catalog = catalog
            @categories_path = categories_path
          end

          def name = "shopify_catalog"

          def description
            "Shopify's global catalog search (catalog.shopify.com) — one query per top-level taxonomy " \
              "node, or --queries FILE. Harvests merchant origins from variants[].url and product " \
              "identities from the results."
          end

          def source_path = nil

          # @param queries [Array<String>, nil] nil (the default) runs one
          #   query per top-level taxonomy node.
          # @return [Array<Hash>] sightings: origin:, url:, title:, brand:,
          #   gtin:.
          def candidates(queries: nil)
            (queries || default_queries).flat_map { |query| sightings_for(query) }
          end

          private

          def sightings_for(query)
            @catalog.offers(query, limit: PER_QUERY_LIMIT, context: BuyerContext.from_env).map do |offer|
              { origin: offer[:store], url: offer[:url], title: offer[:title], brand: nil, gtin: nil }
            end
          rescue StandardError
            []
          end

          # The shipped taxonomy's own top-level keyword ("animals",
          # "apparel", "electronics", ...) rather than its full name — a
          # single plain word is a better catalog search term than
          # "Apparel & Accessories" would be.
          def default_queries
            data = YAML.safe_load_file(@categories_path)
            return [] unless data.is_a?(Hash)

            top_level = data.values.reject { |node| node["name"].to_s.include?(">") }
            top_level.filter_map { |node| Array(node["keywords"]).first }.uniq
          rescue StandardError
            []
          end
        end
      end
    end
  end
end
