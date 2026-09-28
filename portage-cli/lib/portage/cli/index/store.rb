require "json"
require "fileutils"
require "uri"

module Portage
  module Cli
    module Index
      # `~/.portage/index/stores.json` — one entry per merchant origin
      # `portage index build`/`refresh`/`add` has found and verified.
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
      # Entry shape (string keys, JSON on disk): origin, platform,
      # ucp_version, capabilities (array of "catalog"/"cart"/"checkout"),
      # webmcp_preset, categories (category id => weight, top 5),
      # sources (array of source names that found it), last_verified
      # (unix seconds), handoff_only.
      class Store
        PATH = File.join(Dir.home, ".portage", "index", "stores.json").freeze

        def initialize(path: PATH)
          @path = path
        end

        def all = entries.values

        def find(origin) = entries[origin]

        # Merges `fields` onto whatever's already there for `origin` (or
        # starts a fresh entry) — so a second source finding the same store
        # adds to its `sources`/`categories` rather than clobbering the
        # first source's findings.
        def upsert(origin, **fields)
          existing = entries[origin] || { "origin" => origin }
          entries[origin] = existing.merge(fields.transform_keys(&:to_s))
          write
          entries[origin]
        end

        # @return [Integer] how many entries (0 or 1 — origins are unique)
        #   this host's removal actually dropped.
        def remove(host)
          before = entries.length
          entries.reject! { |origin, _| host_of(origin) == host }
          write
          before - entries.length
        end

        # @return [Integer, nil] seconds since the oldest entry was
        #   verified — nil when the index is empty. `doctor` and `index
        #   show` use this to say how stale the local index is.
        def oldest_verified_age(now: Time.now)
          timestamps = entries.values.filter_map { |e| e["last_verified"] }
          return nil if timestamps.empty?

          now.to_i - timestamps.min
        end

        def exists? = File.exist?(@path)

        private

        def host_of(origin)
          URI.parse(origin).host.to_s
        rescue URI::InvalidURIError
          ""
        end

        def entries
          @entries ||= read
        end

        def read
          return {} unless File.readable?(@path)

          # A business name/title can carry non-ASCII bytes (curly quotes,
          # ®, accents); reading with the process's default external
          # encoding (US-ASCII on a bare-minimal LANG, confirmed live in a
          # sandbox with no locale set) would otherwise raise on the very
          # first non-ASCII byte and get silently swallowed below, quietly
          # dropping the whole file's worth of entries — this was caught by
          # this phase's own live index-build check.
          parsed = JSON.parse(File.read(@path, encoding: "UTF-8"))
          parsed.is_a?(Hash) ? parsed : {}
        rescue StandardError
          {}
        end

        # An index that can't be written just means this run's findings
        # aren't saved — never a failed build.
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
