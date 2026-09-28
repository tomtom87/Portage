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
      # Nothing personal ships in the export: a store entry whose only
      # `sources` is "browser" (history/bookmark-derived — Phase 3) is
      # dropped outright, and "browser" is stripped from the `sources` of
      # any entry that also has a real source, so a store found both by
      # `shopify_catalog` and by browsing history exports as if browsing
      # history had never touched it. ProductStore entries carry no
      # `sources` field of their own (see ProductStore's header comment),
      # so a product is kept only if at least one of its `stores[].origin`
      # survived that same filter, and its `stores` array is itself
      # trimmed to just those surviving origins.
      class Exporter
        BROWSER_SOURCE = "browser".freeze

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
        # *only* source; otherwise the entry with "browser" stripped out of
        # its own `sources` list, so a mixed-source entry still exports —
        # just with no trace that browsing history ever found it too.
        def exportable_store(entry)
          sources = Array(entry["sources"])
          return nil if sources == [BROWSER_SOURCE]

          entry.merge("sources" => sources - [BROWSER_SOURCE])
        end

        # A product with no surviving store origin is exactly as personal
        # as a store entry with only "browser" as its source — it only
        # exists in the index because of something the user looked at, not
        # something a source discovered — so it's dropped the same way.
        def exportable_product(entry, exportable_origins)
          kept_stores = Array(entry["stores"]).select { |s| exportable_origins.include?(s["origin"]) }
          return nil if kept_stores.empty?

          entry.merge("stores" => kept_stores)
        end

        def write(dir, filename, entries, key:)
          data = entries.to_h { |entry| [entry[key], entry] }
          File.write(File.join(dir, filename), JSON.generate(data))
        end
      end
    end
  end
end
