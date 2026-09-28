require "uri"

require_relative "../classifier"
require_relative "../index"
require_relative "../index/builder"
require_relative "profiles"
require_relative "readers"
require_relative "filter"
require_relative "prober"
require_relative "categorize"
require_relative "saver"
require_relative "domains"

module Portage
  module Cli
    module BrowserImport
      # `portage browser import` (docs/plans/buy-skill-and-local-browser.md
      # Phase 3, Tier A): bookmarks and history in, a short list of shop
      # domains out, written to the user's own Index::Store only after the
      # user has seen the list and said yes (Cli.run_browser_import owns
      # that gate; this class only ever writes from #save).
      #
      # #plan reads the profile's allowed files (Profiles::ALLOWED_FILES,
      # nothing else), reduces every row to its domain, and decides each
      # domain locally first — skipped as an obvious non-shop (Filter),
      # excluded by the user, on the hand-off-only list, or already in the
      # index — before spending one of at most `max_probes` Prober probes
      # on an unknown one. A domain is kept only when it answers
      # `/.well-known/ucp`, matches a WebMCP preset, or is hand-off only.
      # Each kept domain is classified from what the user actually looked
      # at there (page titles, bookmark folder names, URL slugs), weighted
      # by visit count.
      #
      # Kept domains land in Index::Store with `sources: ["history"]`/
      # `["bookmark"]` — the same untrusted index every other source
      # writes, so an imported store reaches `find` only as a
      # `source: "index"` candidate (never Policy#merchant_allowlist, never
      # past the `--store`/interactive pick a `--yes` buy requires), and
      # Index::Exporter treats both labels as personal: never exported.
      class Importer
        DEFAULT_HISTORY_DAYS = 90
        MAX_PROBES = 200

        FULL_DISK_ACCESS = "macOS won't let this terminal read Safari's history and bookmarks without Full Disk " \
                           "Access. To allow it, open System Settings > Privacy & Security > Full Disk Access, " \
                           "turn it on for the terminal app you run portage from, then quit and reopen that app " \
                           "and re-run this command. Portage doesn't try any other way in. Nothing was imported, " \
                           "probed or saved.".freeze

        # Any other browser: the same "explain and stop", without claiming
        # to know which protection said no (macOS privacy settings, a
        # sandboxed terminal, file permissions).
        PERMISSION_DENIED = "Permission denied reading %<browser>s's profile folder. If your terminal runs " \
                            "sandboxed or macOS is protecting that folder, allow access (System Settings > " \
                            "Privacy & Security > Full Disk Access) and re-run. Portage doesn't try any other way " \
                            "in. Nothing was imported, probed or saved.".freeze

        Options = Struct.new(:browser, :root, :history_days, :include_product_pages, :max_probes, :exclude,
                             keyword_init: true) do
          def initialize(history_days: DEFAULT_HISTORY_DAYS, include_product_pages: false, max_probes: MAX_PROBES,
                         exclude: [], **)
            super
          end
        end

        # @param handoff_only_hosts [Array<String>] Tier C hosts (Phase 5
        #   will supply the user's own `handoff_only_hosts:` config; nothing
        #   ships that list yet, so it defaults to empty). A history domain
        #   on it is kept — hand-off only, never probed, never automated.
        # @param webmcp_preset_for [#call, nil] `->(origin) { preset_or_nil }`.
        #   Matching a WebMCP preset needs a browser bridge an import doesn't
        #   have (same posture as Index::Sources::WebmcpSweep), so nil (the
        #   default) skips the check entirely.
        # @param readers [#call] `->(family) { reader }` — see Readers.for.
        def initialize(stores: Index::Store.new, products: Index::ProductStore.new,
                       known_cache: Index::KnownCache.new, prober: Prober.new, handoff_only_hosts: [],
                       webmcp_preset_for: nil, readers: Readers.method(:for), now: Time.now)
          @stores = stores
          @products = products
          @known_cache = known_cache
          @prober = prober
          @handoff_only_hosts = handoff_only_hosts.map { |h| h.to_s.downcase.delete_prefix("www.") }
          @webmcp_preset_for = webmcp_preset_for
          @readers = readers
          @now = now
        end

        # @return [Hash] the proposal: counts, `kept` (domains to save) and
        #   `products` (only with include_product_pages) — or `error:` /
        #   `message:` when the browser's files couldn't be read (Safari
        #   without Full Disk Access, no sqlite3, no profile found).
        def plan(options)
          profiles = Profiles.locate(options.browser, root: options.root)
          return no_profile(options) if profiles.empty?

          rows, opened = read_rows(profiles, since: @now.to_i - (options.history_days.to_i * 86_400))
          summarize(options, profiles, opened, rows)
        rescue Sqlite::PermissionDenied
          permission_denied(options)
        rescue Sqlite::Unavailable => e
          { browser: options.browser, error: "reader_unavailable",
            message: "Couldn't read the browser's files: #{e.message}." }
        end

        # Writes a #plan's kept domains (and products) into the index — see
        # Saver.
        # @return [Hash] stores:, products: — how many entries were written.
        def save(proposal) = Saver.new(stores: @stores, products: @products, now: @now).save(proposal)

        private

        # --- Reading ---

        def read_rows(profiles, since:)
          opened = []
          rows = profiles.flat_map do |profile|
            reader = @readers.call(profile.family)
            opened.concat([profile.history, profile.bookmarks].compact)
            reader.history(profile, since: since) + reader.bookmarks(profile)
          end
          [rows, opened.uniq]
        end

        # --- Deciding each domain ---

        def summarize(options, profiles, opened, rows)
          groups = Domains.group(rows)
          state = { skipped: Hash.new(0), kept: [], cached_miss: 0, not_ucp: 0, unprobed: 0 }
          groups.sort_by { |_key, g| -g[:visits] }.each { |key, group| decide(key, group, options, state) }
          report(options, profiles, opened, rows, groups, state)
        end

        def decide(key, group, options, state)
          reason = local_skip_reason(key, options)
          return state[:skipped][reason] += 1 if reason

          verdict = local_verdict(key) || probe_verdict(Domains.origin_for(group), options, state)
          state[:kept] << kept_entry(key, group, verdict) if verdict
        end

        def local_skip_reason(key, options)
          return :excluded if Array(options.exclude).any? { |h| h.to_s.downcase.delete_prefix("www.") == key }

          Filter.skip_reason(key)
        end

        # Everything decidable with no network call at all.
        def local_verdict(key)
          return { verdict: "handoff_only", handoff_only: true } if handoff_only?(key)

          own = own_entry(key)
          return { verdict: "indexed", origin: own["origin"] } if own

          known = known_entry(key)
          return unless known

          { verdict: "known", origin: known["origin"], capabilities: known["capabilities"],
            last_verified: known["last_verified"] }
        end

        # A cached "no UCP" verdict or the probe cap skips the probe, but
        # not the WebMCP check (when a bridge is injected) — a page can
        # expose WebMCP tools without any manifest at all.
        def probe_verdict(origin, options, state)
          session = ucp_session(origin, options, state)
          return nil if session == :capped
          return { verdict: "ucp", origin: origin, capabilities: Index::Builder.capabilities_of(session) } if session

          preset = @webmcp_preset_for&.call(origin)
          return { verdict: "webmcp", origin: origin, webmcp_preset: preset } if preset

          state[:not_ucp] += 1 unless session == false
          nil
        end

        # @return [Session, nil, false, :capped] a session; nil when the
        #   probe found no UCP; false for a cached miss (no request made);
        #   :capped once max_probes is spent.
        def ucp_session(origin, options, state)
          if @prober.cached_miss?(origin)
            state[:cached_miss] += 1
            false
          elsif @prober.probes >= options.max_probes.to_i
            state[:unprobed] += 1
            :capped
          else
            @prober.probe(origin)
          end
        end

        def handoff_only?(key)
          @handoff_only_hosts.any? { |h| key == h || key.end_with?(".#{h}") }
        end

        def own_entry(key) = @stores.all.find { |e| Domains.key_of(e["origin"]) == key }

        def known_entry(key) = @known_cache.stores.values.find { |e| Domains.key_of(e["origin"]) == key }

        # --- The proposal ---

        def kept_entry(key, group, verdict)
          { domain: key, origin: verdict[:origin] || Domains.origin_for(group), verdict: verdict[:verdict],
            sources: group[:rows].map { |r| r[:kind] }.uniq.sort, visits: group[:visits],
            categories: Categorize.domain(group[:rows]), rows: group[:rows] }
            .merge(verdict.slice(:capabilities, :webmcp_preset, :handoff_only, :last_verified))
        end

        def report(options, profiles, opened, rows, groups, state)
          kept = state[:kept]
          { browser: options.browser, profiles: profiles.length, files_opened: opened, rows: row_counts(rows),
            domains: groups.length, skipped: state[:skipped].transform_keys(&:to_s),
            already_indexed: count(kept, "indexed"), known: count(kept, "known"), probed: @prober.probes,
            cached_miss: state[:cached_miss], not_ucp: state[:not_ucp], unprobed: state[:unprobed],
            capped: state[:unprobed].positive?, kept: kept.map { |entry| public_entry(entry) },
            products: options.include_product_pages ? Categorize.products(kept) : [] }
        end

        def row_counts(rows)
          kinds = rows.map { |r| r[:kind] }
          { history: kinds.count("history"), bookmark: kinds.count("bookmark") }
        end

        def public_entry(entry)
          entry.except(:rows).merge(category_names: Classifier.names_for(entry[:categories].keys))
        end

        def count(kept, verdict) = kept.count { |e| e[:verdict] == verdict }

        # --- Helpers ---

        def no_profile(options)
          where = options.root ? " under #{options.root}" : ""
          { browser: options.browser, error: "no_profile",
            message: "No #{options.browser} profile with history or bookmarks found#{where}." }
        end

        def permission_denied(options)
          if options.browser == "safari"
            { browser: "safari", error: "full_disk_access_required", message: FULL_DISK_ACCESS }
          else
            { browser: options.browser, error: "permission_denied",
              message: format(PERMISSION_DENIED, browser: options.browser) }
          end
        end
      end
    end
  end
end
