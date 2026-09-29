require "uri"
require "securerandom"
require "portage/ucp"
require "portage/ucp/client"

require_relative "search_backends"
require_relative "offer_sources"
require_relative "agent_profile_url"
require_relative "probe_cache"
require_relative "decisions"
require_relative "user_agent"
require_relative "handoff_only"

module Portage
  module Cli
    # `portage find --query "..."` — the "I don't have a URL" half of the CLI.
    #
    # Ask a search backend which stores might sell the thing, keep only the
    # ones that answer `/.well-known/ucp`, ask each of those what it actually
    # stocks, and return the merged offers. Buy then takes over from a store
    # the caller picked.
    #
    # The split matters: Find never buys. Handing the merchant choice to a
    # search ranker and the purchase decision to `--yes` in one breath is how
    # you end up owning a counterfeit from a shop you've never heard of, so
    # picking a store stays an explicit act (see Cli.run_buy's `--store` gate).
    class Find
      CART_CAP = "dev.ucp.shopping.cart".freeze
      CHECKOUT_CAP = "dev.ucp.shopping.checkout".freeze
      MAX_PROBES = 12
      PER_STORE_RESULTS = 5
      THROTTLE = 0.1

      # @param max_price [Integer, nil] minor units, matching the protocol's
      #   own money representation — the CLI converts from major units.
      # @param offer_sources [Array<#offers>, nil] a second kind of backend
      #   (OfferSources) that answers offers directly, with no manifest
      #   probe of its own — see #call. nil (the default) is
      #   OfferSources.default.
      # @param handoff_only [HandoffOnly, nil] Tier C's host list
      #   (docs/plans/buy-skill-and-local-browser.md Phase 5) — nil (the
      #   default) is the real ~/.portage/config.json-backed one. A
      #   candidate on it is never probed (see #call): it still surfaces as
      #   a candidate, marked `handoff_only: true`, so an agent can list it
      #   ("Amazon also sells this") without this process ever fetching it.
      def initialize(query:, limit: MAX_PROBES, max_price: nil, backends: nil, cache: nil, throttle: THROTTLE,
                     offer_sources: nil, handoff_only: nil)
        @query = query.to_s
        @limit = [limit, MAX_PROBES].min
        @max_price = max_price
        @backends = backends || SearchBackends.default
        @cache = cache || ProbeCache.new
        @throttle = throttle
        @offer_sources = offer_sources || OfferSources.default
        @handoff_only = handoff_only || HandoffOnly.new
      end

      def call
        return report(message: "Nothing to search for — pass --query.") if @query.strip.empty?

        candidates = candidate_origins
        probed, stores = probe_candidates(candidates)
        sourced = source_offers
        return report(candidates: candidates, message: no_candidates_message) if nothing_to_go_on?(candidates, sourced)

        offers = rank(sourced + probed.flat_map { |store| offers_for(store) }).map { |o| with_offer_ref(o) }
        report(candidates: candidates, stores: store_summaries(stores), offers: offers,
               message: summary(candidates, stores, offers))
      rescue Portage::Ucp::Client::MissingAgentProfileError
        report(candidates: candidates, stores: store_summaries(stores),
               message: "Set PORTAGE_AGENT_PROFILE to a URL that describes this agent — each store " \
                        "verifies it before answering a catalog search.")
      end

      private

      # Neither the URL backends nor any OfferSource found anything to
      # probe or rank — split out of #call to keep its own branching under
      # the complexity budget.
      def nothing_to_go_on?(candidates, sourced) = candidates.empty? && sourced.empty?

      # A short opaque id `portage buy --offer` resolves from history, so a
      # later step can point at one offer without re-sending its store,
      # product id and query. Added last, after ranking, so it never
      # influences the order.
      def with_offer_ref(offer) = { offer_ref: "of_#{SecureRandom.hex(3)}" }.merge(offer)

      # --- Step 1: ask the backends who might sell this ---

      def candidate_origins
        seen = {}
        @backends.each do |backend|
          urls_from(backend).each { |url| add_candidate(seen, backend, url) }
        end
        seen.values.first(@limit)
      end

      # Keyed by host rather than by full origin: backends routinely hand back
      # both `http://` and `https://` for the same shop, and probing one host
      # twice over two schemes is a wasted request every time. https wins when
      # both show up; an http-only host is still probed as it was given. The
      # backend credited stays the one that found the host first.
      def add_candidate(seen, backend, url)
        uri = parse_http(url)
        return unless uri

        existing = seen[uri.host]
        return if existing && !upgradable?(existing, uri)

        seen[uri.host] = { origin: origin_of(uri), source: existing ? existing[:source] : backend.name,
                           handoff_only: @handoff_only.host?(uri.host) }
      end

      # Tier C candidates never reach #probe — no UCP request, ever — but
      # still surface in the report's `stores`, `checkout: false`.
      def handoff_only_stores(candidates)
        candidates.map { |c| c.merge(checkout: false) }
      end

      # Splits candidates into the ones #probe actually fetches and the
      # Tier C ones that never touch the network — kept out of #call to
      # stay under its own complexity budget.
      # @return [Array(Array<Hash>, Array<Hash>)] probed stores (the ones
      #   with a live `session`, so #offers_for can ask them what they
      #   stock), and every store for the report (probed + hand-off-only).
      def probe_candidates(candidates)
        probeable, deferred = candidates.partition { |c| !c[:handoff_only] }
        probed = probe(probeable)
        [probed, probed + handoff_only_stores(deferred)]
      end

      def store_summaries(stores)
        stores.map { |s| s.slice(:origin, :source, :checkout, :handoff_only) }
      end

      # --- Step 1b: ask any OfferSources directly, no probe needed ---

      # Each source already returns Find#offer-shaped hashes (store:/
      # source:/checkout:/product_id:/title:/amount:/currency:/url:) and
      # swallows its own failures, so nothing here needs the try/rescue
      # #urls_from gives the URL backends. --max-price applies here exactly
      # as it does to a probed store's offers in #offer.
      def source_offers
        offers = @offer_sources.flat_map do |source|
          source.offers(@query, limit: PER_STORE_RESULTS, context: BuyerContext.from_env)
        end
        offers.reject { |offer| over_max_price?(offer[:amount]) }
      end

      def upgradable?(existing, uri)
        uri.scheme == "https" && existing[:origin].start_with?("http://")
      end

      # One backend being down, rate-limited, or misconfigured shouldn't take
      # the whole search with it.
      def urls_from(backend)
        Array(backend.search(@query, limit: @limit))
      rescue StandardError
        []
      end

      def parse_http(url)
        uri = URI.parse(url.to_s)
        uri if uri.host && uri.scheme.to_s.start_with?("http")
      rescue URI::InvalidURIError
        nil
      end

      # Collapse every deep link a backend returns onto the origin, since
      # that's the only thing `/.well-known/ucp` hangs off.
      def origin_of(uri)
        port = uri.port == uri.default_port ? "" : ":#{uri.port}"
        "#{uri.scheme}://#{uri.host}#{port}"
      end

      # --- Step 2: keep the ones that actually speak UCP ---

      # A cached *miss* is the only verdict that saves work here — a cached hit
      # still has to connect, because a live session is the thing we need next.
      def probe(candidates)
        probed = 0
        candidates.filter_map do |candidate|
          next if @cache.fetch(candidate[:origin]) == false

          throttle(probed)
          probed += 1
          session = discover(candidate[:origin])
          @cache.record(candidate[:origin], !session.nil?)
          session && candidate.merge(session: session, checkout: checkout?(session))
        end
      end

      def throttle(probed)
        sleep(@throttle) if probed.positive? && @throttle.to_f.positive?
      end

      def discover(origin)
        Portage::Ucp::Client.discover(origin, headers: UserAgent.headers)
      rescue StandardError
        nil
      end

      def checkout?(session)
        session.advertises?(CART_CAP) && session.advertises?(CHECKOUT_CAP)
      end

      # --- Step 3: ask the survivors what they stock ---

      def offers_for(store)
        products = CatalogProducts.from(
          store[:session].search_catalog(query: @query, limit: PER_STORE_RESULTS,
                                         context: BuyerContext.from_env, meta: agent_meta)
        )
        products.filter_map { |product| offer(store, product) }
      rescue Portage::Ucp::Client::MissingAgentProfileError
        raise
      rescue StandardError
        []
      end

      # Real UCP servers fetch this URL to verify the caller's identity
      # before answering any call (see Transports::Http) — the own-store
      # loopback path ignores it harmlessly.
      def agent_meta
        { agent_profile: AgentProfileUrl.resolve }
      end

      def offer(store, product)
        amount, currency = price_of(product)
        return nil if over_max_price?(amount)

        { store: store[:origin], source: store[:source], checkout: store[:checkout],
          product_id: field(product, "id"), title: field(product, "title"),
          amount: amount, currency: currency, url: field(product, "url") }
      end

      # An unpriced offer stays in: no price isn't the same as too dear.
      def over_max_price?(amount) = @max_price && amount && amount > @max_price

      # Buyable first, then cheapest, then unpriced (see Decisions.rank —
      # core's Support::OfferRanking, the rule portage-ucp-decision's
      # OfferRanking wraps), so an agent loop ranking its own candidate list
      # gets the same order this command prints. Sorting on price alone
      # would float a browse-only store above one you can actually check
      # out from, which is the wrong answer to "buy me this".
      def rank(offers) = Decisions.rank(offers)

      # --- Shapes ---

      # Every product here comes from #offers_for, which reads through
      # Session#search_catalog — Dispatcher#wrap has already called
      # #to_wire_h on the result, so this is always a string-keyed wire hash,
      # never a raw Portage::Ucp::Product struct (same posture as
      # Buy#product_id_of), and it carries a `price_range` rather than a
      # scalar price.
      def price_of(product)
        range = field(product, "price_range")
        return [money_amount(range["min"]), range["min"]["currency"]] if range.is_a?(Hash) && range["min"].is_a?(Hash)

        scalar_price(field(product, "price"))
      end

      def scalar_price(price)
        case price
        when Hash then [money_amount(price), price["currency"]]
        when Integer then [price, nil]
        when nil then [nil, nil]
        else [price.respond_to?(:amount_minor) ? price.amount_minor : nil,
              price.respond_to?(:currency) ? price.currency : nil]
        end
      end

      def money_amount(price) = price["amount"]

      def field(product, key) = product[key]

      def report(**fields)
        { query: @query, candidates: [], stores: [], offers: [], message: nil }.merge(fields)
      end

      def no_candidates_message
        names = @backends.map(&:name)
        return no_backends_message if names.empty?

        "No candidate stores came back from #{names.join(', ')} for \"#{@query}\".#{keyed_backend_hint}"
      end

      def no_backends_message
        "No search backend available — set BRAVE_SEARCH_API_KEY, GOOGLE_CSE_KEY/GOOGLE_CSE_CX, " \
          "or list stores in ~/.portage/stores.yml."
      end

      # DuckDuckGo's free Instant Answer API is the keyless default, but it
      # only answers *entity* queries ("burton snowboards" → burton.com) —
      # open-ended shopping terms like "coffee" or "iphone" resolve to
      # nothing, every time, regardless of what those stores actually stock
      # (see SearchBackends::DuckDuckGo's own comment). Names alone (e.g.
      # `no_candidates_message`) don't say *why* nothing came back, so this
      # spells out the fix rather than leaving the caller to guess whether
      # it's a network problem or a backend limitation. Only fires when no
      # keyed backend (Brave/Google CSE) ran alongside it — one of those
      # already covered the query with real web search, so there's nothing
      # to suggest.
      def keyed_backend_hint
        return "" unless SearchBackends.only_duckduckgo?(@backends)

        " DuckDuckGo's free API only resolves specific brand/product names, not open-ended search — " \
          "set BRAVE_SEARCH_API_KEY or GOOGLE_CSE_KEY/GOOGLE_CSE_CX for real web search " \
          "(see `portage doctor`)."
      end

      def summary(candidates, stores, offers)
        # Counted from the offers, not `stores`: an OfferSource's offers
        # come from stores that were never probed.
        selling = offers.map { |o| o[:store] }.uniq.length
        return "Found #{offers.length} offer(s) across #{selling} store(s)." if offers.any?
        return "#{stores.length} store(s) speak UCP but none stock \"#{@query}\"." if stores.any?

        "Checked #{candidates.length} store(s); none of them speak UCP."
      end
    end
  end
end
