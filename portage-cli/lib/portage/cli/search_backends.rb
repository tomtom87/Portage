require "net/http"
require "uri"
require "json"
require "yaml"

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
      USER_AGENT = "portage-find".freeze

      # Reference works and marketplaces-of-links that a search backend will
      # happily return for a product query but that are never themselves a UCP
      # store — cheap to skip, and each one skipped is one fewer host we probe.
      NON_STORE_HOSTS = %w[
        wikipedia.org wikimedia.org duckduckgo.com google.com bing.com
        reddit.com youtube.com facebook.com x.com twitter.com pinterest.com
      ].freeze

      # Ordered cheapest/most-trusted first: your own allowlist costs no
      # network call and needs no key, DuckDuckGo needs no key, the keyed
      # engines only participate when their credentials are actually present.
      def self.default
        [Allowlist.new, DuckDuckGo.new, Brave.new, GoogleCse.new].select(&:available?)
      end

      def self.get_json(uri, params: {}, headers: {})
        uri = uri.dup
        uri.query = URI.encode_www_form(params) unless params.empty?
        response = request(uri, headers)
        response.is_a?(Net::HTTPSuccess) ? JSON.parse(response.body) : nil
      rescue StandardError
        nil
      end

      def self.request(uri, headers)
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                            open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
          http.get(uri.request_uri, { "User-Agent" => USER_AGENT }.merge(headers))
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
      # `~/.portage/stores.yml` (a bare YAML array of URLs) or `PORTAGE_STORES`
      # (comma-separated — the PATH-style colon can't separate values that
      # contain `https://`). Query-independent on purpose: the point of the file
      # is "always consider these", and the store's own catalog search is what
      # decides whether it stocks the thing.
      class Allowlist
        PATH = File.join(Dir.home, ".portage", "stores.yml").freeze

        def initialize(path: PATH, env: ENV.fetch("PORTAGE_STORES", nil))
          @path = path
          @env = env
        end

        def name = "allowlist"

        def available? = !entries.empty?

        def search(_query, limit: 10) = entries.first(limit)

        private

        def entries
          @entries ||= (env_entries + file_entries).map { |e| e.to_s.strip }.reject(&:empty?).uniq
        end

        def env_entries = @env.to_s.split(",")

        def file_entries
          return [] unless File.readable?(@path)

          Array(YAML.safe_load_file(@path))
        rescue StandardError
          []
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
