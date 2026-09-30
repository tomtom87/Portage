require "net/http"
require "uri"
require "json"
require "portage/ucp/support/connection"

require_relative "../../../user_agent"

module Portage
  module Cli
    module Index
      module Sources
        class StorefrontProducts
          # The HTTP half of a crawl: GETs `products.json?limit=&page=`
          # through Support::Connection with the shared UserAgent, pausing
          # between pages, waiting out one 429's Retry-After and stopping on
          # a second, and turning anything that isn't a products array into
          # a reason.
          class Pages
            PAUSE = 1
            MAX_RETRY_AFTER = 60
            DEFAULT_RETRY_AFTER = 10
            OPEN_TIMEOUT = 5
            READ_TIMEOUT = 20

            def self.get(url, accept: "application/json")
              uri = URI.parse(url)
              headers = UserAgent.headers.merge("Accept" => accept)
              Portage::Ucp::Support::Connection.start(uri, route: :store, open_timeout: OPEN_TIMEOUT,
                                                           read_timeout: READ_TIMEOUT) do |http|
                http.get(uri.request_uri, headers)
              end
            end

            # @param allowed [#call] path -> whether robots.txt allows it.
            def initialize(endpoint, per_page:, max_pages:, sleeper:, allowed: ->(_path) { true })
              @endpoint = endpoint
              @path = URI.parse(endpoint).path
              @allowed = allowed
              @per_page = per_page
              @max_pages = max_pages
              @sleeper = sleeper
              @rate_limited = 0
            end

            # Yields each non-empty page's raw products.
            # @return [Array(String, String, Integer)] status ("ok",
            #   "partial", "skipped"), reason (nil when ok) and pages read.
            def each(&)
              (1..@max_pages).each do |page|
                @sleeper.call(PAUSE) if page > 1
                products = fetch(page)
                done = outcome(products, page, &)
                return done if done
              end
              ["partial", "page_cap", @max_pages]
            end

            private

            # nil means "full page, keep going".
            def outcome(products, page)
              return failed(products, page - 1) unless products.is_a?(Array)
              return ["skipped", "empty", 0] if products.empty? && page == 1

              yield products unless products.empty?
              ["ok", nil, page] if products.length < @per_page
            end

            # Past page 1 a failure keeps what earlier pages found.
            def failed(reason, pages) = [pages.zero? ? "skipped" : "partial", reason, pages]

            # @return [Array<Hash>, String] a page's products, or why there
            #   are none.
            def fetch(page)
              return "robots" unless @allowed.call("#{@path}#{query(page)}")

              response = self.class.get("#{@endpoint}#{query(page)}")
              return products_in(response) unless response.code == "429"

              @rate_limited += 1
              return "rate_limited" if @rate_limited > 1

              @sleeper.call(retry_after(response["Retry-After"]))
              fetch(page)
            rescue StandardError => e
              "error: #{e.class}"
            end

            # Page 1 is the bare URL (Shopify's default page), so a robots
            # rule aimed at duplicate `?page=1` URLs doesn't read as a ban
            # on the whole catalogue.
            def query(page) = page == 1 ? "?limit=#{@per_page}" : "?limit=#{@per_page}&page=#{page}"

            def products_in(response)
              return "not_found" if response.code == "404"
              return "redirect" if response.is_a?(Net::HTTPRedirection)
              return "http_#{response.code}" unless response.is_a?(Net::HTTPSuccess)

              body = JSON.parse(response.body.to_s.dup.force_encoding(Encoding::UTF_8))
              body.is_a?(Hash) && body["products"].is_a?(Array) ? body["products"] : "not_json"
            rescue JSON::ParserError
              "not_json"
            end

            def retry_after(value)
              seconds = Integer(value.to_s, exception: false) || DEFAULT_RETRY_AFTER
              seconds.clamp(0, MAX_RETRY_AFTER)
            end
          end
        end
      end
    end
  end
end
