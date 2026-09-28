require "uri"
require "portage/ucp/client"

require_relative "../user_agent"
require_relative "../classifier"
require_relative "../probe_cache"
require_relative "../handoff_only"
require_relative "store"
require_relative "product_store"
require_relative "known_cache"
require_relative "exporter"
require_relative "sources"

module Portage
  module Cli
    module Index
      # `portage index build`/`refresh`/`add` — runs each configured
      # Sources::* against the user's own machine, verifies any new origin
      # with one `/.well-known/ucp` probe through the existing ProbeCache
      # (throttled, capped at MAX_NEW_PROBES per run), and writes the
      # survivors into Store/ProductStore.
      #
      # Never writes Portage::Ucp::Policy#merchant_allowlist, and never
      # decides what `--yes` treats as "picked a store" — this only ever
      # produces candidates SearchBackends::Index hands to `find`, on the
      # same footing as any other search backend (see Store's own comment).
      class Builder
        CATALOG_CAP = "dev.ucp.shopping.catalog".freeze
        CART_CAP = "dev.ucp.shopping.cart".freeze
        CHECKOUT_CAP = "dev.ucp.shopping.checkout".freeze
        CAPABILITY_PREFIXES = { "catalog" => CATALOG_CAP, "cart" => CART_CAP, "checkout" => CHECKOUT_CAP }.freeze

        # Duplicated from Find::MAX_PROBES/THROTTLE rather than required —
        # same reasoning as SearchBackends::Allowlist::TOTAL_CAP: this class
        # is usable (and tested) with no dependency on find.rb.
        MAX_NEW_PROBES = 500
        THROTTLE = 0.1
        STALE_AFTER = 7 * 24 * 60 * 60
        TOP_CATEGORIES = 5

        # Public so BrowserImport::Importer (Phase 3) labels a probed
        # origin's capabilities exactly the way an index build does.
        # @return [Array<String>] "catalog"/"cart"/"checkout", in that order.
        def self.capabilities_of(session)
          CAPABILITY_PREFIXES.filter_map do |label, prefix|
            label if Array(session.capabilities).any? { |c| c == prefix || c.start_with?("#{prefix}.") }
          end
        end

        def initialize(stores: Store.new, products: ProductStore.new, cache: ProbeCache.new, sources: nil,
                       throttle: THROTTLE, max_new_probes: MAX_NEW_PROBES, out: $stdout, now: Time.now,
                       known_cache: KnownCache.new, handoff_only: nil)
          @stores = stores
          @products = products
          @cache = cache
          @sources = sources || Sources.default
          @throttle = throttle
          @max_new_probes = max_new_probes
          @out = out
          @now = now
          @known_cache = known_cache
          @handoff_only = handoff_only || HandoffOnly.new
        end

        # @param queries [Array<String>, nil] passed through to every
        #   source that takes one (today, just shopify_catalog).
        # @param export [String, nil] a directory to also write a PR-ready
        #   `{stores,products}.json` into (see Exporter) — nil (the
        #   default) skips it.
        # @return [Hash] a run summary — sources_run, candidates,
        #   new_origins_checked, verified, products_added, capped, and
        #   (with `export:`) exported.
        def build(queries: nil, dry_run: false, export: nil)
          sightings = gather(queries)
          result = apply(sightings, dry_run: dry_run)
          result[:exported] = Exporter.new(stores: @stores, products: @products).export(export) if export
          result
        end

        # Re-verifies every entry older than 7 days (bumping last_verified
        # only for the ones still answering), refreshes the known-stores
        # cache unconditionally (Phase 2c — this is one of the three
        # triggers the plan names, alongside a first-run fetch and a stale
        # `doctor` check), then runs an ordinary #build, which itself adds
        # anything new the sources turn up.
        def refresh(queries: nil, dry_run: false, export: nil)
          @known_cache.refresh! unless dry_run
          reverify_stale(dry_run: dry_run)
          build(queries: queries, dry_run: dry_run, export: export).merge(refreshed: true)
        end

        # `portage index add URL` — verifies and stores one origin
        # directly, no source involved. A hand-off-only origin (Tier C,
        # HandoffOnly) is recorded without ever probing it — the user
        # explicitly named it, but that's still not a request this process
        # sends.
        def add(url)
          origin = origin_of(url)
          return { added: false, message: "Not a valid http(s) URL: #{url}" } unless origin
          return store_manual_handoff_only(origin) if handoff_only_origin?(origin)

          session = probe(origin)
          store_manual(origin, session)
        end

        # `portage index remove HOST`
        def remove(host)
          removed = @stores.remove(host).positive?
          { removed: removed,
            message: removed ? "Removed #{host} from the index." : "No index entry for #{host}." }
        end

        private

        def gather(queries)
          @sources.flat_map { |source| candidates_from(source, queries) }
        end

        # One source failing shouldn't take the rest of the build with it —
        # same posture as SearchBackends#urls_from/OfferSources.
        def candidates_from(source, queries)
          source.candidates(queries: queries).map { |c| c.merge(source: source.name) }
        rescue StandardError
          []
        end

        def apply(sightings, dry_run:)
          grouped = sightings.group_by { |s| s[:origin] }
          probed = probe_new_origins(grouped, dry_run: dry_run)
          products_added = dry_run ? 0 : store_products(sightings)
          { sources_run: @sources.map(&:name), candidates: sightings.length, products_added: products_added,
            new_origins_checked: probed[:checked], verified: probed[:verified], capped: probed[:capped] }
        end

        def probe_new_origins(grouped, dry_run:)
          state = { checked: [], verified: [], probes: 0, capped: false }
          grouped.each { |origin, group| probe_one_new_origin(origin, group, state, dry_run: dry_run) }
          state.slice(:checked, :verified, :capped)
        end

        def probe_one_new_origin(origin, group, state, dry_run:)
          if @stores.find(origin)
            update_existing(origin, group) unless dry_run
            return
          end
          return handoff_only_new_origin(origin, group, dry_run: dry_run) if handoff_only_origin?(origin)
          return state[:capped] = true if state[:probes] >= @max_new_probes

          throttle(state[:probes])
          state[:probes] += 1
          state[:checked] << origin
          progress("Probing #{origin}...")
          session = probe(origin)
          return unless session

          state[:verified] << origin
          store_new(origin, session, group) unless dry_run
        end

        # Never spends a probe (docs/plans/buy-skill-and-local-browser.md
        # Phase 5) — recorded straight as `handoff_only: true`, same as a
        # `store_new` verdict but with no capabilities and no request ever
        # made.
        def handoff_only_new_origin(origin, group, dry_run:)
          return if dry_run

          @stores.upsert(origin, platform: platform_of(group), capabilities: [],
                                 categories: merge_categories({}, group), sources: merged_sources(nil, group),
                                 last_verified: @now.to_i, handoff_only: true)
        end

        def handoff_only_origin?(origin) = @handoff_only.host?(host_of(origin))

        def host_of(origin)
          URI.parse(origin).host
        rescue URI::InvalidURIError
          nil
        end

        def store_manual_handoff_only(origin)
          existing = @stores.find(origin)
          sources = ((existing && existing["sources"]) || []) + ["manual"]
          @stores.upsert(origin, sources: sources.uniq, last_verified: @now.to_i, handoff_only: true)
          { added: true, origin: origin, message: "Added #{origin} — hand-off only, never probed." }
        end

        def update_existing(origin, group)
          existing = @stores.find(origin)
          @stores.upsert(origin, sources: merged_sources(existing, group),
                                 categories: merge_categories(existing["categories"], group))
        end

        def store_new(origin, session, group)
          @stores.upsert(origin, platform: platform_of(group), capabilities: capabilities_of(session),
                                 categories: merge_categories({}, group), sources: merged_sources(nil, group),
                                 last_verified: @now.to_i, handoff_only: false)
        end

        def store_manual(origin, session)
          existing = @stores.find(origin)
          sources = ((existing && existing["sources"]) || []) + ["manual"]
          if session
            @stores.upsert(origin, platform: existing && existing["platform"], capabilities: capabilities_of(session),
                                   sources: sources.uniq, last_verified: @now.to_i, handoff_only: false)
            { added: true, origin: origin, message: "Added #{origin} — verified UCP." }
          else
            @stores.upsert(origin, sources: sources.uniq, last_verified: @now.to_i, handoff_only: true)
            { added: true, origin: origin,
              message: "Added #{origin} — no /.well-known/ucp response; marked hand-off only." }
          end
        end

        def merged_sources(existing, group)
          (Array(existing && existing["sources"]) + group.map { |g| g[:source] }).uniq
        end

        def merge_categories(existing, group)
          tally = Hash.new(0)
          Array(existing).each { |id, weight| tally[id] += weight.to_i }
          group.each do |sighting|
            next unless sighting[:title]

            Classifier.categories_for(sighting[:title]).each { |id| tally[id] += 1 }
          end
          tally.sort_by { |_id, weight| -weight }.first(TOP_CATEGORIES).to_h
        end

        def platform_of(group)
          "shopify" if group.any? { |g| g[:source] == "shopify_catalog" }
        end

        def capabilities_of(session) = self.class.capabilities_of(session)

        def store_products(sightings)
          eligible = sightings.select { |s| s[:title] && @stores.find(s[:origin]) }
          eligible.each { |sighting| store_product(sighting) }
          eligible.length
        end

        def store_product(sighting)
          key = product_key(sighting)
          category = Classifier.categories_for(sighting[:title]).first
          @products.upsert(key, origin: sighting[:origin], seen_at: @now.to_i, title: sighting[:title],
                                brand: sighting[:brand], gtin: sighting[:gtin], category: category,
                                sources: [sighting[:source]].compact)
        end

        # GTIN when a source has one (none do yet); otherwise a normalized
        # brand+title slug, stable across runs so the same product seen
        # again updates its entry instead of duplicating it.
        def product_key(sighting)
          return "gtin:#{sighting[:gtin]}" if sighting[:gtin]

          slug = [sighting[:brand], sighting[:title]].compact.join(" ").downcase.gsub(/[^a-z0-9]+/, "-")
          "title:#{slug}"
        end

        # Skips by whether the origin is *currently* hand-off only
        # (`handoff_only_origin?`, checked against live config), never by
        # the flag a previous run happened to store — those disagree in
        # both directions: an origin whose UCP probe simply failed is
        # stored `handoff_only: true` too (#store_new/#store_manual) but
        # isn't on the Tier C list and should keep getting re-verified in
        # case it comes online, while a stale entry recorded *before* the
        # user added its host to `handoff_only_hosts` is stored
        # `handoff_only: false` and must stop being probed the moment that
        # config changes, without waiting for some other source to
        # re-sight it. An origin caught by the live check gets its stored
        # flag flipped to match — no request, just a `last_verified` bump
        # so it isn't re-checked again until the next stale window.
        def reverify_stale(dry_run:)
          probes = 0
          @stores.all.select { |e| stale?(e) }.each do |entry|
            origin = entry["origin"]
            next reverify_now_handoff_only(origin, dry_run: dry_run) if handoff_only_origin?(origin)
            break if probes >= @max_new_probes

            throttle(probes)
            probes += 1
            progress("Re-verifying #{origin}...")
            session = probe(origin)
            @stores.upsert(origin, capabilities: capabilities_of(session), last_verified: @now.to_i) \
              if session && !dry_run
          end
        end

        def reverify_now_handoff_only(origin, dry_run:)
          return if dry_run

          @stores.upsert(origin, handoff_only: true, last_verified: @now.to_i)
        end

        def stale?(entry)
          verified = entry["last_verified"]
          verified.nil? || (@now.to_i - verified.to_i) > STALE_AFTER
        end

        # A cached *miss* saves the work; a cached hit still has to connect
        # for the manifest details this run wants (same posture as
        # Find#probe).
        def probe(origin)
          return nil if @cache.fetch(origin) == false

          session = discover(origin)
          @cache.record(origin, !session.nil?)
          session
        end

        def discover(origin)
          Portage::Ucp::Client.discover(origin, headers: UserAgent.headers)
        rescue StandardError
          nil
        end

        def throttle(probed)
          sleep(@throttle) if probed.positive? && @throttle.to_f.positive?
        end

        def progress(message)
          @out&.puts(message)
        end

        def origin_of(url)
          uri = URI.parse(url.to_s)
          return nil unless uri.host && uri.scheme.to_s.start_with?("http")

          port = uri.port == uri.default_port ? "" : ":#{uri.port}"
          "#{uri.scheme}://#{uri.host}#{port}"
        rescue URI::InvalidURIError
          nil
        end
      end
    end
  end
end
