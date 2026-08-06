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
        include Portage::Ucp::Support::HttpClient

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
          json_request(http_method, "#{BASE_URL}#{path}",
                       headers: { "Authorization" => "Bearer #{@access_token}", "x-api-key" => @api_key })
        end

        def api_error_class = Portage::Ucp::Etsy::ApiError
      end
    end
  end
end
