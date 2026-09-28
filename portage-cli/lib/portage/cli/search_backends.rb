require "net/http"
require "uri"
require "json"
require "yaml"
require "portage/ucp"
require "portage/ucp/support/connection"
require_relative "user_agent"
require_relative "classifier"
require_relative "index/store"
require_relative "index/product_store"
require_relative "index/known_cache"

module Portage
  module Cli
    # Where "which stores might sell this?" comes from when the caller never
    # named a store.
    #
    # Every backend here talks to a documented machine interface and returns
    # bare candidate URLs. None of them parse a results page: scraping a search
    # engine's HTML is the same class of ToS violation Buy already refuses to
    # commit against a merchant, and it would be odd to be scrupulous about the
    # shop and cavalier about the index. That rules out the usual
    # `html.duckduckgo.com/html/?q=` trick — see DuckDuckGo below for what we
    # use instead and what it costs us.
    module SearchBackends
      OPEN_TIMEOUT = 5
      READ_TIMEOUT = 5

      # Reference works and marketplaces-of-links that a search backend will
      # happily return for a product query but that are never themselves a UCP
      # store — cheap to skip, and each one skipped is one fewer host we probe.
      NON_STORE_HOSTS = %w[
        wikipedia.org wikimedia.org duckduckgo.com google.com bing.com
        reddit.com youtube.com facebook.com x.com twitter.com pinterest.com
      ].freeze

      # Ordered cheapest/most-trusted first: your own allowlist costs no
      # network call and needs no key, the local index next (still no
      # network call, but untrusted — see Index's own comment), DuckDuckGo
      # needs no key, the keyed engines only participate when their
      # credentials are actually present.
      def self.default
        [Allowlist.new, Index.new, DuckDuckGo.new, Brave.new, GoogleCse.new].select(&:available?)
      end

      # True when the only thing standing between the caller and a real web
      # search is a missing API key — i.e. DuckDuckGo's entity-only Instant
      # Answer API is running solo, with no allowlist and no keyed backend
      # (Brave/Google CSE) to cover the open-ended queries it can't answer.
      # Used to decide whether "no candidates" is worth a nudge to set
      # BRAVE_SEARCH_API_KEY / GOOGLE_CSE_KEY+GOOGLE_CSE_CX (see Find and
      # Doctor) rather than a plain "nothing found".
      def self.only_duckduckgo?(backends) = backends.map(&:name) == ["duckduckgo"]

      def self.get_json(uri, params: {}, headers: {})
        uri = uri.dup
        uri.query = URI.encode_www_form(params) unless params.empty?
        response = request(uri, headers)
        response.is_a?(Net::HTTPSuccess) ? JSON.parse(response.body) : nil
      rescue StandardError
        nil
      end

      def self.request(uri, headers)
        Portage::Ucp::Support::Connection.start(uri, route: :search, open_timeout: OPEN_TIMEOUT,
                                                     read_timeout: READ_TIMEOUT) do |http|
          http.get(uri.request_uri, UserAgent.headers.merge(headers))
        end
      end
      private_class_method :request

      # @return [Boolean] true when the URL is worth spending a manifest probe on.
      def self.store_candidate?(url)
        host = URI.parse(url.to_s).host
        !!host && NON_STORE_HOSTS.none? { |bad| host == bad || host.end_with?(".#{bad}") }
      rescue URI::InvalidURIError
        false
      end

      # Stores you've already decided you trust, listed in
      # `~/.portage/stores.yml` (a bare YAML array of URLs, or an array
      # mixing in `{url:, categories: [...]}` entries once you've tagged
      # some) or `PORTAGE_STORES` (comma-separated — the PATH-style colon
      # can't separate values that contain `https://`).
      #
      # Trust stays query-independent: every entry is *always* a candidate
      # to `find`, on the same footing whether it's tagged or not, and the
      # store's own catalog search is still what decides whether it stocks
      # the thing. `categories:` only changes which of these already-trusted
      # entries get spent on *this* query's dozen probe slots — a stores.yml
      # with fifty tagged stores across a dozen categories used to crowd out
      # web-search candidates on every single query; #search now routes by
      # the query's own category instead of just taking the first N.
      class Allowlist
        PATH = File.join(Dir.home, ".portage", "stores.yml").freeze

        # At most this many of a matching category's tagged stores per
        # `#search` call, so one heavily-tagged category can't fill every
        # probe slot by itself.
        PER_CATEGORY_CAP = 3

        # The hard ceiling regardless of the caller's own `limit:` — mirrors
        # Find::MAX_PROBES (duplicated rather than required, to avoid
        # search_backends.rb depending on find.rb) since this backend can be
        # constructed and searched outside Find too.
        TOTAL_CAP = 12

        def initialize(path: PATH, env: ENV.fetch("PORTAGE_STORES", nil))
          @path = path
          @env = env
        end

        def name = "allowlist"

        def available? = !entries.empty?

        # @return [Array<String>] URLs, routed by #categorized_search.
        def search(query, limit: 10) = categorized_search(query, [limit, TOTAL_CAP].min).map { |e| e[:url] }

        # @return [Array<Hash>] every entry (url:, categories:), untouched
        #   by any query — Index::Sources::StoresFile reuses this to seed
        #   the local index from the same file, rather than re-parsing
        #   stores.yml itself.
        def stores = entries

        private

        # Named entries always come first (an explicit "buy from <store>"
        # outranks a category guess), then up to PER_CATEGORY_CAP tagged
        # entries per matching category not already named. When no tagged
        # entry matches any of the query's categories at all, this falls
        # back to named entries plus every untagged entry — the pre-Phase-
        # 2a behaviour for an all-untagged stores.yml — but never to every
        # entry once a tagged match exists: a tagged-but-unrelated store
        # stays excluded, which is the crowding this routing exists to fix.
        def categorized_search(query, limit)
          named = named_entries(query)
          category_ids = Classifier.categories_for(query)
          return fallback(named, limit) unless any_tagged_match?(category_ids)

          remaining = [limit - named.length, 0].max
          matched = by_category(category_ids, remaining, named)
          (named + matched).uniq { |e| e[:url] }.first(limit)
        end

        def any_tagged_match?(category_ids)
          category_ids.any? { |category_id| entries.any? { |e| e[:categories].include?(category_id) } }
        end

        # Named entries plus every untagged entry, capped — not every
        # entry: a tagged store whose categories didn't match the query
        # stays out, the same as it would once a tagged match exists.
        def fallback(named, limit)
          (named + entries.select { |e| e[:categories].empty? }).uniq { |e| e[:url] }.first(limit)
        end

        def by_category(category_ids, limit, exclude)
          picked = []
          category_ids.each do |category_id|
            entries_for_category(category_id, exclude).each do |entry|
              break if picked.length >= limit

              picked << entry unless picked.include?(entry)
            end
          end
          picked
        end

        def entries_for_category(category_id, exclude)
          entries.select { |e| e[:categories].include?(category_id) && !exclude.include?(e) }.first(PER_CATEGORY_CAP)
        end

        # host or bare name ("shop" out of "shop.example") mentioned in the
        # query — the escape hatch for "buy from <store>" regardless of
        # what it's tagged, or for an untagged store the caller named.
        def named_entries(query)
          entries.select { |e| named?(e, query) }
        end

        def named?(entry, query)
          host = host_of(entry[:url])
          return false if host.empty?

          label = host.sub(/\Awww\./, "").split(".").first.to_s
          downcased = query.to_s.downcase
          downcased.include?(host) || (label.length > 2 && downcased.include?(label))
        end

        def host_of(url)
          URI.parse(url).host.to_s.downcase
        rescue URI::InvalidURIError
          ""
        end

        def entries
          @entries ||= (env_entries + file_entries).uniq { |e| e[:url] }
        end

        def env_entries
          @env.to_s.split(",").map(&:strip).reject(&:empty?).map { |url| { url: url, categories: [] } }
        end

        def file_entries
          return [] unless File.readable?(@path)

          Array(YAML.safe_load_file(@path)).filter_map { |entry| normalize(entry) }
        rescue StandardError
          []
        end

        # A bare string (the format before Phase 2a, still the common case)
        # or a `{url:, categories: [...]}` hash — both parse, per the plan's
        # "the file stays a bare URL list; an entry becomes tagged only when
        # it carries categories:".
        def normalize(entry)
          case entry
          when String
            url = entry.strip
            url.empty? ? nil : { url: url, categories: [] }
          when Hash
            normalize_hash(entry)
          end
        end

        def normalize_hash(entry)
          entry = entry.transform_keys(&:to_s)
          url = entry["url"].to_s.strip
          return nil if url.empty?

          { url: url, categories: Array(entry["categories"]).map(&:to_s) }
        end
      end

      # `~/.portage/index/stores.json` — origins `portage index build`
      # found and verified itself (docs/plans/buy-skill-and-local-browser.md
      # Phase 2b). Unlike Allowlist, this data is **untrusted**: nothing
      # here was ever typed in by the user, so an entry never skips a probe
      # (Find still re-verifies it through ProbeCache like any other
      # candidate URL) and never becomes a `merchant_allowlist`/`--yes`
      # shortcut — it's just another URL a search backend handed back,
      # ranked below Allowlist and above the web-search backends in
      # SearchBackends.default (search_backends_spec.rb has specs proving
      # both non-shortcuts).
      #
      # Routes the same way Allowlist routes a tagged stores.yml (up to
      # PER_CATEGORY_CAP per matching category, TOTAL_CAP overall), plus
      # one thing stores.yml can't do: match a query against a *product* the
      # index has seen (by name or GTIN) and put that product's own stores
      # first, ahead of a category guess. A store the query names outright
      # comes next (Phase 3 — the only route an uncategorised
      # `portage browser import` domain ever gets).
      #
      # Phase 2c: also draws on the repo's own known-stores cache
      # (Index::KnownCache) — fetched lazily the first time this backend is
      # asked for anything and no cache exists yet — merged *underneath*
      # the user's own Store/ProductStore entries: a known entry only shows
      # up when the user's own index doesn't already have that origin/key,
      # so a local `index add`/`index build` finding always wins. Still the
      # same untrusted posture either way — an offer built from either
      # source carries `source: "index"`, never a merchant_allowlist/--yes
      # shortcut (see this class's own header comment).
      class Index
        PER_CATEGORY_CAP = 3
        TOTAL_CAP = 12

        def initialize(stores: Portage::Cli::Index::Store.new, products: Portage::Cli::Index::ProductStore.new,
                       known: Portage::Cli::Index::KnownCache.new)
          @stores = stores
          @products = products
          @known = known
        end

        def name = "index"

        def available? = !store_entries.empty? || !product_entries.empty?

        def search(query, limit: 10)
          return [] if store_entries.empty? && product_entries.empty?

          product_origins = origins_for_products(query)
          named = named_origins(query, exclude: product_origins)
          category_origins = origins_for_categories(Classifier.categories_for(query), exclude: product_origins + named)
          (product_origins + named + category_origins).uniq.first([limit, TOTAL_CAP].min)
        end

        private

        def store_entries
          @store_entries ||= merge_under_own(@stores.all, known_stores, key: "origin")
        end

        def product_entries
          @product_entries ||= merge_under_own(@products.all, known_products, key: "key")
        end

        # `entry[key]` is always present on both sides — Store#upsert seeds
        # "origin" and ProductStore#upsert seeds "key" the same way on a
        # brand-new entry, and KnownCache's own fetch just carries whatever
        # `portage index build --export` wrote, in the same schema.
        def merge_under_own(own, known, key:)
          own_keys = own.map { |e| e[key] }
          own + known.reject { |e| own_keys.include?(e[key]) }
        end

        def known_stores
          ensure_known_cache!
          @known.stores.values
        end

        def known_products
          ensure_known_cache!
          @known.products.values
        end

        # Fetched at most once per instance — a cache miss found here means
        # "still no cache", not "try again this call".
        def ensure_known_cache!
          return if @known_cache_checked

          @known_cache_checked = true
          @known.fetch_if_missing!
        end

        def origins_for_products(query)
          matches = product_entries.select { |product| product_matches?(product, query) }
          matches.flat_map { |product| Array(product["stores"]).map { |s| s["origin"] } }.uniq
        end

        # Whole-word matching, built on the same Classifier.tokenize/
        # .word_match? a title/query is classified into categories with
        # (docs/plans/buy-skill-and-local-browser.md Phase 2a) — a plain
        # substring check goes both ways regardless of word boundaries
        # ("tea" inside "steam"/"teak", "bag" inside "bagel"), which is
        # exactly the false-positive class 2a already fixed for category
        # keywords and this backend was still exposed to.
        #
        # A match is either every one of the query's tokens found among the
        # title/alias's own tokens (a short query naming a longer title,
        # e.g. "hiking boots" -> "Men's Hiking Boot"), or the reverse (a
        # longer query that names the whole title/alias as a phrase, e.g.
        # "where can I buy a trail boot"). An empty/whitespace-only query
        # tokenizes to nothing and matches no product.
        def product_matches?(product, query)
          return true if gtin_match?(product, query)

          # Checked after GTIN, not before: a purely numeric query (the
          # normal shape of a GTIN) tokenizes to nothing at all —
          # Classifier.tokenize splits on runs of non-alpha characters — so
          # gating on "any tokens" first would refuse a valid barcode
          # lookup before #gtin_match? ever got to compare it.
          query_tokens = Classifier.tokenize(query)
          return false if query_tokens.empty?

          [product["title"], *Array(product["aliases"])].compact.any? { |text| title_matches?(query_tokens, text) }
        end

        # Exact match against the whole (stripped, downcased) query, never a
        # substring — a GTIN is a barcode, not a word Classifier.tokenize
        # would even keep (it splits on runs of non-alpha characters, so a
        # purely numeric query tokenizes to nothing).
        def gtin_match?(product, query)
          gtin = product["gtin"]
          !gtin.to_s.empty? && query.to_s.strip.downcase == gtin.to_s.downcase
        end

        def title_matches?(query_tokens, text)
          title_tokens = Classifier.tokenize(text)
          return false if title_tokens.empty?

          all_match?(query_tokens, title_tokens) || all_match?(title_tokens, query_tokens)
        end

        def all_match?(these, those)
          these.all? { |a| those.any? { |b| Classifier.word_match?(a, b) } }
        end

        # A store the query names outright — its host ("allbirds.com") or
        # its bare name as a whole word ("buy from allbirds") — whether or
        # not it carries categories. This is the only way an uncategorised
        # entry (a `portage browser import` domain whose titles matched no
        # category — Phase 3) is ever routed: by name, never for a generic
        # query.
        def named_origins(query, exclude:)
          tokens = Classifier.tokenize(query)
          text = query.to_s.downcase
          store_entries.filter_map do |entry|
            origin = entry["origin"]
            origin if !exclude.include?(origin) && names_store?(origin, text, tokens)
          end
        end

        def names_store?(origin, text, tokens)
          host = URI.parse(origin.to_s).host.to_s.downcase.delete_prefix("www.")
          return false if host.empty?

          text.include?(host) || tokens.include?(host.split(".").first)
        rescue URI::InvalidURIError
          false
        end

        def origins_for_categories(category_ids, exclude:)
          picked = []
          category_ids.each do |category_id|
            entries_for_category(category_id, exclude + picked).each do |origin|
              break if picked.length >= TOTAL_CAP

              picked << origin
            end
          end
          picked
        end

        # Ranked by this category's own weight (how many of the store's
        # products the Classifier put there — see Index::Builder's
        # #merge_categories), highest first, before PER_CATEGORY_CAP cuts
        # it off, so a store barely tagged into a category doesn't take a
        # slot from one the Classifier weighted heavily into it.
        def entries_for_category(category_id, exclude)
          matches = store_entries.select do |e|
            Array(e["categories"]&.keys).include?(category_id) && !exclude.include?(e["origin"])
          end
          ranked = matches.sort_by { |e| -e["categories"][category_id].to_i }
          ranked.first(PER_CATEGORY_CAP).map { |e| e["origin"] }
        end
      end

      # DuckDuckGo's Instant Answer API — official, documented, no key
      # (https://api.duckduckgo.com/api).
      #
      # Know what it is before you lean on it: it answers *entity* queries, not
      # web queries. "burton snowboards" resolves to burton.com through
      # `Results`; "snowboard" resolves to nothing at all. So it covers "buy me
      # a <brand> thing" well and open-ended shopping not at all. It's the
      # keyless default because it's the only no-key engine with a real API;
      # pair it with Brave or a Google CSE for actual breadth.
      class DuckDuckGo
        ENDPOINT = "https://api.duckduckgo.com/".freeze

        def name = "duckduckgo"

        def available? = true

        def search(query, limit: 10)
          data = SearchBackends.get_json(
            URI.parse(ENDPOINT),
            params: { q: query, format: "json", no_html: "1", no_redirect: "1", t: "portage" }
          )
          return [] unless data

          urls(data).select { |u| SearchBackends.store_candidate?(u) }.uniq.first(limit)
        end

        private

        # `Results` is the official-site answer and the only genuinely
        # commercial field. `RelatedTopics` is mostly duckduckgo.com category
        # links (filtered out downstream) but occasionally carries a real
        # vendor, so it's worth flattening. `AbstractURL` is deliberately
        # ignored — it's the encyclopedia entry, never the shop.
        def urls(data)
          direct = Array(data["Results"]).map { |r| r["FirstURL"] }
          related = Array(data["RelatedTopics"]).flat_map { |topic| topic_urls(topic) }
          (direct + related).compact
        end

        def topic_urls(topic)
          return [] unless topic.is_a?(Hash)
          return Array(topic["Topics"]).flat_map { |t| topic_urls(t) } if topic["Topics"]

          [topic["FirstURL"]].compact
        end
      end

      # Brave Search API (https://api-dashboard.search.brave.com) — real web
      # results, needs BRAVE_SEARCH_API_KEY. This is the backend to set up if
      # you want URL-less buying to work for generic queries.
      class Brave
        ENDPOINT = "https://api.search.brave.com/res/v1/web/search".freeze

        def initialize(api_key: ENV.fetch("BRAVE_SEARCH_API_KEY", nil))
          @api_key = api_key
        end

        def name = "brave"

        def available? = !@api_key.to_s.empty?

        def search(query, limit: 10)
          data = SearchBackends.get_json(
            URI.parse(ENDPOINT),
            params: { q: query, count: limit },
            headers: { "Accept" => "application/json", "X-Subscription-Token" => @api_key }
          )
          return [] unless data

          Array(data.dig("web", "results")).map { |r| r["url"] }.compact
                                           .select { |u| SearchBackends.store_candidate?(u) }.first(limit)
        end
      end

      # Google Programmable Search (Custom Search JSON API) — needs
      # GOOGLE_CSE_KEY and GOOGLE_CSE_CX. The documented API, not the SERP.
      class GoogleCse
        ENDPOINT = "https://www.googleapis.com/customsearch/v1".freeze

        def initialize(api_key: ENV.fetch("GOOGLE_CSE_KEY", nil), cx: ENV.fetch("GOOGLE_CSE_CX", nil))
          @api_key = api_key
          @cx = cx
        end

        def name = "google_cse"

        def available? = !@api_key.to_s.empty? && !@cx.to_s.empty?

        def search(query, limit: 10)
          data = SearchBackends.get_json(
            URI.parse(ENDPOINT),
            params: { key: @api_key, cx: @cx, q: query, num: [limit, 10].min }
          )
          return [] unless data

          Array(data["items"]).map { |i| i["link"] }.compact
                              .select { |u| SearchBackends.store_candidate?(u) }.first(limit)
        end
      end
    end
  end
end
