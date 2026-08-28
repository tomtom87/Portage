require "uri"
require "portage/ucp"
require "portage/ucp/client"

require_relative "search_backends"
require_relative "probe_cache"

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
      def initialize(query:, limit: MAX_PROBES, max_price: nil, backends: nil, cache: nil, throttle: THROTTLE)
        @query = query.to_s
        @limit = [limit, MAX_PROBES].min
        @max_price = max_price
        @backends = backends || SearchBackends.default
        @cache = cache || ProbeCache.new
        @throttle = throttle
      end

      def call
        return report(message: "Nothing to search for — pass --query.") if @query.strip.empty?

        candidates = candidate_origins
        return report(candidates: candidates, message: no_candidates_message) if candidates.empty?

        stores = probe(candidates)
        offers = rank(stores.flat_map { |store| offers_for(store) })
        report(candidates: candidates, stores: stores.map { |s| s.slice(:origin, :source, :checkout) },
               offers: offers, message: summary(candidates, stores, offers))
      end

      private

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

        seen[uri.host] = { origin: origin_of(uri), source: existing ? existing[:source] : backend.name }
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
        Portage::Ucp::Client.discover(origin)
      rescue StandardError
        nil
      end

      def checkout?(session)
        session.advertises?(CART_CAP) && session.advertises?(CHECKOUT_CAP)
      end

      # --- Step 3: ask the survivors what they stock ---

      def offers_for(store)
        products = CatalogProducts.from(store[:session].search_catalog(query: @query, limit: PER_STORE_RESULTS))
        products.filter_map { |product| offer(store, product) }
      rescue StandardError
        []
      end

      def offer(store, product)
        amount, currency = price_of(product)
        return nil if @max_price && amount && amount > @max_price

        { store: store[:origin], source: store[:source], checkout: store[:checkout],
          product_id: field(product, "id"), title: field(product, "title"),
          amount: amount, currency: currency, url: field(product, "url") }
      end

      # Buyable first, then cheapest, then unpriced. Sorting on price alone
      # would float a browse-only store above one you can actually check out
      # from, which is the wrong answer to "buy me this".
      def rank(offers)
        offers.sort_by do |offer|
          [offer[:checkout] ? 0 : 1, offer[:amount] ? 0 : 1, offer[:amount] || 0]
        end
      end

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

        "No candidate stores came back from #{names.join(', ')} for \"#{@query}\"."
      end

      def no_backends_message
        "No search backend available — set BRAVE_SEARCH_API_KEY, GOOGLE_CSE_KEY/GOOGLE_CSE_CX, " \
          "or list stores in ~/.portage/stores.yml."
      end

      def summary(candidates, stores, offers)
        return "Found #{offers.length} offer(s) across #{stores.length} UCP store(s)." if offers.any?
        return "#{stores.length} store(s) speak UCP but none stock \"#{@query}\"." if stores.any?

        "Checked #{candidates.length} store(s); none of them speak UCP."
      end
    end
  end
end
