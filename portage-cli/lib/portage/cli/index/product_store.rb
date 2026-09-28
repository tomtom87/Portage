require "json"
require "fileutils"

module Portage
  module Cli
    module Index
      # `~/.portage/index/products.json` — product identities the index has
      # seen, one entry per GTIN/MPN (when a source gives one) or per
      # title+brand otherwise. **No prices or stock** — those are always
      # live, read straight from the store's own catalog at buy time
      # (docs/plans/buy-skill-and-local-browser.md Phase 2b).
      #
      # Entry shape: title, brand, gtin, category, aliases (other titles the
      # same product went by at a different store), stores (array of
      # {origin:, last_seen:}).
      class ProductStore
        PATH = File.join(Dir.home, ".portage", "index", "products.json").freeze

        def initialize(path: PATH)
          @path = path
        end

        def all = entries.values

        def find(key) = entries[key]

        # @param key [String] a stable key for this product — the source's
        #   GTIN/MPN when it has one, else a normalized title+brand.
        # @param origin [String] the store this sighting came from.
        # @param seen_at [Integer] unix seconds.
        def upsert(key, origin:, seen_at:, **fields)
          existing = entries[key] || { "key" => key, "aliases" => [], "stores" => [] }
          aliases = merge_aliases(existing, fields[:title])
          merged = existing.merge(fields.transform_keys(&:to_s)) { |field, old, new| merge_field(field, old, new) }
          merged["aliases"] = aliases
          merged["stores"] = merge_stores(merged["stores"], origin, seen_at)
          entries[key] = merged
          write
          merged
        end

        def exists? = File.exist?(@path)

        private

        # `aliases`/`stores` accumulate across upserts; every other field
        # (title, brand, gtin, category) is just the latest sighting's
        # value, since a later source's read is no less authoritative than
        # an earlier one's.
        def merge_field(field, old, new)
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

        def entries
          @entries ||= read
        end

        def read
          return {} unless File.readable?(@path)

          # See Index::Store#read's comment — a product title routinely
          # carries non-ASCII bytes, so this has to read as UTF-8 rather
          # than whatever the process's default external encoding is.
          parsed = JSON.parse(File.read(@path, encoding: "UTF-8"))
          parsed.is_a?(Hash) ? parsed : {}
        rescue StandardError
          {}
        end

        def write
          FileUtils.mkdir_p(File.dirname(@path))
          File.write(@path, JSON.generate(@entries))
        rescue StandardError
          nil
        end
      end
    end
  end
end
