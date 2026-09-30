require "json"
require_relative "database"
require_relative "search"

module Portage
  module Cli
    module Index
      # The `products` table of `~/.portage/index/index.sqlite3` (Index::Database;
      # `products.json` before docs/plans/local-catalogue.md Phase 1) — product identities the index has
      # seen, one entry per GTIN/MPN (when a source gives one) or per
      # title+brand otherwise. **No prices or stock** — those are always
      # live, read straight from the store's own catalog at buy time
      # (docs/plans/buy-skill-and-local-browser.md Phase 2b).
      #
      # Entry shape: title, brand, gtin, category, aliases (other titles the
      # same product went by at a different store), stores (array of
      # {origin:, last_seen:}), sources (which index sources ever saw it —
      # Phase 3 adds this so Index::Exporter can tell a product only a
      # browser import saw from one a real source found; entries written
      # before it have none).
      class ProductStore
        PATH = File.join(Dir.home, ".portage", "index", "products.json").freeze

        # @param path [String] where the legacy products.json lives (or
        #   would live) — the database sits beside it, and a products.json
        #   found there is imported on first open.
        def initialize(path: PATH)
          @db = Database.new(path: Database.path_for(path))
        end

        def all = @db.entries("products").values

        def find(key) = @db.get("products", key)

        # @param key [String] a stable key for this product — the source's
        #   GTIN/MPN when it has one, else a normalized title+brand.
        # @param origin [String] the store this sighting came from.
        # @param seen_at [Integer] unix seconds.
        def upsert(key, origin:, seen_at:, **fields)
          @db.transaction { merge_and_write(key, origin, seen_at, fields) }
        end

        # A batch of sightings in one transaction — all of them land or,
        # if any raises, none do. Each row is a Hash: `key:`, `origin:`,
        # `seen_at:` plus the same fields #upsert takes. Rows merge in
        # order, so a key repeated in one batch accumulates like two
        # #upsert calls would.
        # @return [Array<Hash>] the merged entries, in row order.
        def upsert_many(rows)
          return [] if rows.empty?

          @db.transaction do
            rows.map do |row|
              fields = row.except(:key, :origin, :seen_at)
              merge_and_write(row.fetch(:key), row.fetch(:origin), row.fetch(:seen_at), fields)
            end
          end
        end

        def exists? = @db.exists?

        def count = @db.count("products")

        # `index show --products`: one page of entries, in insertion order.
        def page(number, per_page:)
          return [] unless exists?

          offset = ([number.to_i, 1].max - 1) * per_page
          rows = @db.execute("SELECT data FROM products ORDER BY id LIMIT ? OFFSET ?", [per_page, offset])
          rows.map { |(data)| JSON.parse(data) }
        end

        # `portage index search` (docs/plans/local-catalogue.md Phase 2):
        # every query word must match title, brand, category or an alias
        # (as a prefix, after dropping a plural ending), best bm25 first.
        # Without FTS5 (a system SQLite built without it) the same filters
        # run as a LIKE scan, unranked. Untrusted seeds, same as every
        # other entry: no price, no stock.
        # @param store [String, nil] a host or URL; matches that host's origin.
        # @return [Array<Hash>] entries.
        def search(query, category: nil, store: nil, limit: 20)
          words = Search.words(query)
          return [] if words.empty? || !exists?

          sql, binds = Search.sql(words, category: category, host: Search.host_of(store), limit: limit,
                                         fts: search_engine == "fts5")
          @db.execute(sql, binds).map { |(data)| JSON.parse(data) }
        end

        # "fts5", or "like" when the database has no products_fts table.
        def search_engine
          return Schema.fts5_available? ? "fts5" : "like" unless exists?

          fts = @db.execute("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'products_fts'")
          fts.empty? ? "like" : "fts5"
        end

        private

        def merge_and_write(key, origin, seen_at, fields)
          existing = @db.get("products", key) || { "key" => key, "aliases" => [], "stores" => [] }
          aliases = merge_aliases(existing, fields[:title])
          merged = existing.merge(fields.transform_keys(&:to_s)) { |field, old, new| merge_field(field, old, new) }
          merged["aliases"] = aliases
          merged["stores"] = merge_stores(merged["stores"], origin, seen_at)
          @db.put("products", key, merged)
          merged
        end

        # `aliases`/`stores` accumulate across upserts (merged separately
        # below), `sources` is the union of every sighting's; every other
        # field (title, brand, gtin, category) is just the latest
        # sighting's value, since a later source's read is no less
        # authoritative than an earlier one's.
        def merge_field(field, old, new)
          return (Array(old) + Array(new)).uniq if field == "sources"

          %w[aliases stores].include?(field) ? old : (new || old)
        end

        # The *previous* title becomes an alias when a later sighting gives
        # a different one — the newest sighting's title stays canonical
        # (see #merge_field), and the one it replaced is kept so a search
        # for either still finds this product.
        def merge_aliases(existing, new_title)
          old_title = existing["title"]
          return Array(existing["aliases"]) if new_title.nil? || old_title.nil? || new_title == old_title

          (Array(existing["aliases"]) + [old_title]).uniq
        end

        def merge_stores(stores, origin, seen_at)
          kept = Array(stores).reject { |s| s["origin"] == origin }
          (kept + [{ "origin" => origin, "last_seen" => seen_at }]).sort_by { |s| s["origin"] }
        end
      end
    end
  end
end
