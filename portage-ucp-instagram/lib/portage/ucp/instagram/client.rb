require "net/http"
require "json"

module Portage
  module Ucp
    module Instagram
      # Minimal REST client over Meta's Graph API
      # (`graph.facebook.com/{api_version}`), used for both Instagram and
      # Facebook Shops — they share one Commerce Catalog underneath.
      #
      # Deliberately plain Net::HTTP, not the `koala`/`facebook-ads-sdk`
      # gems — a generic adapter that any Ruby app can drop in only needs a
      # base URL and a bearer token, trivially stubbable with WebMock.
      class Client
        DEFAULT_API_VERSION = "v21.0".freeze

        def initialize(access_token:, api_version: DEFAULT_API_VERSION)
          @access_token = access_token
          @api_version = api_version
        end

        def get(path)
          req = Net::HTTP::Get.new(URI("https://graph.facebook.com/#{@api_version}#{path}"))
          req["Authorization"] = "Bearer #{@access_token}"

          uri = req.uri
          response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(req) }
          parsed = response.body.nil? || response.body.empty? ? {} : JSON.parse(response.body)
          unless response.is_a?(Net::HTTPSuccess)
            raise Portage::Ucp::Instagram::ApiError.new(response.code.to_i, parsed)
          end

          parsed
        end
      end
    end
  end
end
