require "net/http"
require "json"

module Portage
  module Ucp
    module Etsy
      # Minimal REST client over Etsy's Open API v3
      # (`api.etsy.com/v3/application`).
      #
      # Deliberately plain Net::HTTP, not an Etsy SDK (there isn't an
      # official Ruby one) — trivially stubbable with WebMock.
      #
      # Every call needs *two* credentials, not one: a Bearer access_token
      # from the shop owner's OAuth consent (see
      # Portage::Ucp::Etsy::AccessTokenFetcher) **and** the app's own
      # `x-api-key` (the OAuth client's keystring) on every single request —
      # Etsy checks both independently, unlike Shopify/Wix/WooCommerce/
      # Magento, where the bearer token alone is sufficient.
      class Client
        BASE_URL = "https://api.etsy.com/v3/application".freeze

        def initialize(access_token:, api_key:)
          @access_token = access_token
          @api_key = api_key
        end

        def get(path)
          request(Net::HTTP::Get, path)
        end

        private

        def request(http_method, path)
          req = http_method.new(URI("#{BASE_URL}#{path}"))
          req["Authorization"] = "Bearer #{@access_token}"
          req["x-api-key"] = @api_key

          uri = req.uri
          response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(req) }
          parsed = response.body.nil? || response.body.empty? ? {} : JSON.parse(response.body)
          raise Portage::Ucp::Etsy::ApiError.new(response.code.to_i, parsed) unless response.is_a?(Net::HTTPSuccess)

          parsed
        end
      end
    end
  end
end
