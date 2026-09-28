require "json"
require "fileutils"

module Portage
  module Cli
    module Index
      # `portage index build --export DIR` — writes a PR-ready copy of the
      # user's own local index into `DIR/{stores,products}.json`, in the
      # same shape as `portage-cli/known-stores/` in the repo, so a
      # maintainer's run is just "run this, `git add`, open a PR" (Decision
      # 1a: the user builds the index, not CI).
      #
      # Nothing personal ships in the export. PERSONAL_SOURCES are the
      # labels a browser import writes (`history`/`bookmark` — Phase 3 —
      # plus Phase 2b's placeholder `browser`): a store entry whose only
      # `sources` are personal is dropped outright, and they're stripped
      # from the `sources` of any entry that also has a real source, so a
      # store found both by `shopify_catalog` and by browsing history
      # exports as if browsing history had never touched it. A product
      # entry is filtered the same way on its own `sources` (Phase 3 adds
      # that field — so a product page kept by `browser import
      # --include-product-pages` never exports, even at a store a real
      # source also found), and in any case is kept only if at least one
      # of its `stores[].origin` survived the store filter, with its
      # `stores` array trimmed to just those surviving origins (entries
      # written before Phase 3 carry no `sources`, so that origin check is
      # all they get).
      class Exporter
        PERSONAL_SOURCES = %w[browser history bookmark].freeze

        def initialize(stores:, products:)
          @stores = stores
          @products = products
        end

        # @return [Hash] stores:, products: — counts written, plus dir.
        def export(dir)
          FileUtils.mkdir_p(dir)
          exportable_stores = @stores.all.filter_map { |entry| exportable_store(entry) }
          exportable_origins = exportable_stores.map { |e| e["origin"] }
          exportable_products = @products.all.filter_map { |entry| exportable_product(entry, exportable_origins) }

          write(dir, "stores.json", exportable_stores, key: "origin")
          write(dir, "products.json", exportable_products, key: "key")

          { dir: dir, stores: exportable_stores.length, products: exportable_products.length }
        end

        private

        # nil (never exported) when browsing history/bookmarks are the
        # *only* source; otherwise the entry with every personal label
        # stripped out of its own `sources` list, so a mixed-source entry
        # still exports — just with no trace that browsing history ever
        # found it too.
        def exportable_store(entry)
          return nil if personal_only?(entry)

          entry.merge("sources" => Array(entry["sources"]) - PERSONAL_SOURCES)
        end

        # A product with no surviving store origin is exactly as personal
        # as a store entry with only "browser" as its source — it only
        # exists in the index because of something the user looked at, not
        # something a source discovered — so it's dropped the same way.
        def exportable_product(entry, exportable_origins)
          return nil if personal_only?(entry)

          kept_stores = Array(entry["stores"]).select { |s| exportable_origins.include?(s["origin"]) }
          return nil if kept_stores.empty?

          exported = entry.merge("stores" => kept_stores)
          entry.key?("sources") ? exported.merge("sources" => Array(entry["sources"]) - PERSONAL_SOURCES) : exported
        end

        # True when the entry names at least one source and every one of
        # them is personal. An entry with no `sources` (a product written
        # before Phase 3) or an empty list isn't judged here at all.
        def personal_only?(entry)
          sources = Array(entry["sources"])
          !sources.empty? && (sources - PERSONAL_SOURCES).empty?
        end

        def write(dir, filename, entries, key:)
          data = entries.to_h { |entry| [entry[key], entry] }
          File.write(File.join(dir, filename), JSON.generate(data))
        end
      end
    end
  end
end
