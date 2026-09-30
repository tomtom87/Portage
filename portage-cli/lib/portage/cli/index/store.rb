require "uri"
require_relative "database"

module Portage
  module Cli
    module Index
      # The `stores` table of `~/.portage/index/index.sqlite3` (Index::Database;
      # `stores.json` before docs/plans/local-catalogue.md Phase 1) — one
      # entry per merchant origin `portage index build`/`refresh`/`add` has
      # found and verified.
      #
      # This is untrusted, user-owned data, same posture as `stores.yml`
      # before it's tagged: never checked into git (docs/plans/
      # buy-skill-and-local-browser.md Phase 2b), never written into
      # Portage::Ucp::Policy#merchant_allowlist, and never itself the
      # "picked a store" a `--yes` buy requires — SearchBackends::Index just
      # hands back candidate URLs, same as any other search backend, so
      # `Cli.buy_from_search`'s existing --store/interactive-pick gate
      # applies to an index-sourced offer exactly as it does to a web
      # search result (see search_backends_spec.rb/cli_spec.rb for the
      # specs proving both).
      #
      # Entry shape (string keys, a JSON object per row): origin, platform,
      # ucp_version, capabilities (array of "catalog"/"cart"/"checkout"),
      # webmcp_preset, categories (category id => weight, top 5),
      # sources (array of source names that found it), last_verified
      # (unix seconds), handoff_only.
      class Store
        PATH = File.join(Dir.home, ".portage", "index", "stores.json").freeze

        # @param path [String] where the legacy stores.json lives (or would
        #   live) — the database sits beside it, and a stores.json found
        #   there is imported on first open.
        def initialize(path: PATH)
          @db = Database.new(path: Database.path_for(path))
        end

        def all = @db.entries("stores").values

        def find(origin) = @db.get("stores", origin)

        # Merges `fields` onto whatever's already there for `origin` (or
        # starts a fresh entry) — so a second source finding the same store
        # adds to its `sources`/`categories` rather than clobbering the
        # first source's findings.
        def upsert(origin, **fields)
          @db.transaction do
            existing = @db.get("stores", origin) || { "origin" => origin }
            existing.merge(fields.transform_keys(&:to_s)).tap { |merged| @db.put("stores", origin, merged) }
          end
        end

        # @return [Integer] how many entries (0 or 1 — origins are unique)
        #   this host's removal actually dropped.
        def remove(host)
          @db.transaction do
            doomed = @db.entries("stores").keys.select { |origin| host_of(origin) == host }
            doomed.each { |origin| @db.delete("stores", origin) }
            doomed.length
          end
        end

        # @return [Integer, nil] seconds since the oldest entry was
        #   verified — nil when the index is empty. `doctor` and `index
        #   show` use this to say how stale the local index is.
        def oldest_verified_age(now: Time.now)
          timestamps = all.filter_map { |e| e["last_verified"] }
          return nil if timestamps.empty?

          now.to_i - timestamps.min
        end

        def exists? = @db.exists?

        private

        def host_of(origin)
          URI.parse(origin).host.to_s
        rescue URI::InvalidURIError
          ""
        end
      end
    end
  end
end
