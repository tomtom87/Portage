require "net/http"
require "uri"
require "json"
require "timeout"
require "portage/ucp/support/connection"

require_relative "../../user_agent"

module Portage
  module Cli
    module Index
      module Sources
        # Wikidata SPARQL for retail chains' and brands' official websites
        # (CC0). Optional and **off by default** (Sources.default excludes
        # it) — a live, read-only trial run of this exact query on
        # 2026-09-28 returned real hits (Venchi, DNS, Fix Price, Avtomir and
        # more, each with a genuine official-site URL), which is the bar
        # the plan set for keeping it, but the yield skews toward chains
        # with no UCP/WebMCP support at all — most of what it finds fails
        # the `/.well-known/ucp` probe like any other candidate, same as a
        # web-search backend's own noise. Worth keeping for the rare real
        # hit, not worth running on every default `index build`.
        class Wikidata
          ENDPOINT = "https://query.wikidata.org/sparql".freeze
          TIMEOUT = 15
          LIMIT = 200

          # wd:Q507619 = "retail chain". wdt:P279* walks subclasses, so a
          # supermarket chain or department-store chain tagged as a
          # subclass of retail chain is included too, not just an exact
          # match.
          QUERY = <<~SPARQL
            SELECT ?item ?itemLabel ?website WHERE {
              ?item wdt:P31/wdt:P279* wd:Q507619 .
              ?item wdt:P856 ?website .
              SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
            } LIMIT #{LIMIT}
          SPARQL
                  .freeze

          def name = "wikidata"

          def description
            "Wikidata SPARQL for retail chains' official websites (CC0). Off by default (low yield) " \
              "— opt in with --sources wikidata."
          end

          def source_path = nil

          # `**` accepts (and ignores) the shared Source#candidates(queries:)
          # interface — this source runs one fixed SPARQL query, never the
          # caller's.
          def candidates(**)
            rows = Timeout.timeout(TIMEOUT) { fetch }
            rows.filter_map { |row| sighting_for(row) }
          rescue StandardError
            []
          end

          private

          def fetch
            uri = URI.parse(ENDPOINT)
            uri.query = URI.encode_www_form(query: QUERY)
            headers = UserAgent.headers.merge("Accept" => "application/sparql-results+json")
            response = Portage::Ucp::Support::Connection.start(
              uri, route: :search, open_timeout: 5, read_timeout: TIMEOUT
            ) { |http| http.get(uri.request_uri, headers) }
            return [] unless response.is_a?(Net::HTTPSuccess)

            Array(JSON.parse(response.body).dig("results", "bindings"))
          end

          def sighting_for(row)
            url = row.dig("website", "value")
            origin = origin_of(url)
            return nil unless origin

            { origin: origin, url: url, title: nil, brand: row.dig("itemLabel", "value"), gtin: nil }
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
end
