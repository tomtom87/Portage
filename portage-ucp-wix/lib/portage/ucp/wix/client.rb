require "net/http"
require "json"

module Portage
  module Ucp
    module Wix
      # Minimal REST client over the Wix APIs (www.wixapis.com).
      #
      # Deliberately plain Net::HTTP, not the `wix-ruby-sdk` (there isn't a
      # first-party one) — a generic adapter that any Ruby app can drop in
      # only needs one bearer-style access token and a handful of JSON
      # endpoints, no framework coupling, trivially stubbable with WebMock.
      #
      # Unlike Shopify's split Admin/Storefront APIs with separate tokens,
      # Wix's REST surface (Stores catalog, eCommerce carts/checkouts/orders)
      # is a single API behind one access token — an app's client_credentials
      # token is already scoped to one site via `instance_id` at fetch time
      # (see Portage::Ucp::Wix::AccessTokenFetcher), so there's nothing here
      # analogous to Shopify's per-call token selection.
      class Client
        include Portage::Ucp::Support::HttpClient

        BASE_URL = "https://www.wixapis.com".freeze

        def initialize(access_token:)
          @access_token = access_token
        end

        def get(path)
          request(Net::HTTP::Get, path)
        end

        def post(path, body = {})
          request(Net::HTTP::Post, path, body)
        end

        def patch(path, body = {})
          request(Net::HTTP::Patch, path, body)
        end

        def delete(path)
          request(Net::HTTP::Delete, path)
        end

        private

        def request(http_method, path, body = nil)
          json_request(http_method, "#{BASE_URL}#{path}", body: body,
                                                          headers: { "Authorization" => @access_token })
        end

        def api_error_class = Portage::Ucp::Wix::ApiError
      end
    end
  end
end
