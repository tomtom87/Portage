require_relative "../classifier"
require_relative "../index/builder"

module Portage
  module Cli
    module BrowserImport
      # "Smarter import" (docs/plans/buy-skill-and-local-browser.md Phase
      # 3): a kept domain's categories come from what the user actually
      # looked at there — each row's page title, bookmark folder name and
      # URL slug (`/products/<slug>`, `/collections/<slug>`, `/c/<slug>`,
      # `/category/<slug>`, split on `-`/`_`), run through the same
      # Classifier every other index source uses, and weighted by visit
      # count. A domain none of whose rows matches a category stays
      # uncategorised: SearchBackends::Index then routes it by name only,
      # never for a generic query.
      module Categorize
        TOP_CATEGORIES = Index::Builder::TOP_CATEGORIES

        # A product page, for `--include-product-pages`: `/product/<x>` or
        # `/products/<x>` (Shopify, WooCommerce and most others).
        PRODUCT_PATH = %r{/products?/[^/?#]+}

        # @param rows [Array<Hash>] Readers rows, all for one domain.
        # @return [Hash{String => Integer}] category id => weight, top 5 (equal
        #   weights in the order first seen).
        def self.domain(rows)
          texts = Hash.new(0)
          rows.each { |row| texts[text_of(row)] += row[:visits] }
          tally = Hash.new(0)
          texts.each do |text, visits|
            Classifier.categories_for(text).each { |id| tally[id] += visits } unless text.empty?
          end
          # `sort_by` isn't stable, so the position breaks ties: first seen wins.
          tally.each_with_index.sort_by { |(_id, weight), seen| [-weight, seen] }.first(TOP_CATEGORIES)
               .to_h { |pair, _seen| pair }
        end

        # @param kept [Array<Hash>] Importer's kept entries, rows included.
        # @return [Array<Hash>] one product entry per distinct product-page
        #   title — key, title, url, origin, source ("history"/"bookmark"),
        #   category.
        def self.products(kept)
          kept.flat_map { |entry| products_of(entry) }.uniq { |p| p[:key] }
        end

        def self.products_of(entry)
          entry[:rows].select { |r| r[:url].match?(PRODUCT_PATH) && !r[:title].empty? }.map do |row|
            { key: "title:#{row[:title].downcase.gsub(/[^a-z0-9]+/, '-')}", title: row[:title], url: row[:url],
              origin: entry[:origin], source: row[:kind], category: Classifier.categories_for(text_of(row)).first }
          end
        end
        private_class_method :products_of

        def self.text_of(row)
          slugs = Classifier::SLUG_PATTERNS.filter_map { |pattern| pattern.match(row[:url])&.[](1) }
          [row[:title], row[:folder], *slugs.map { |s| s.tr("-_", "  ") }].reject(&:empty?).join(" ")
        end
        private_class_method :text_of
      end
    end
  end
end
