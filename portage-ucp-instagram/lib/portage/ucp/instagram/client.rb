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
        include Portage::Ucp::Support::HttpClient

        DEFAULT_API_VERSION = "v21.0".freeze

        def initialize(access_token:, api_version: DEFAULT_API_VERSION)
          @access_token = access_token
          @api_version = api_version
        end

        def get(path)
          json_request(Net::HTTP::Get, "https://graph.facebook.com/#{@api_version}#{path}",
                       headers: { "Authorization" => "Bearer #{@access_token}" })
        end

        private

        def api_error_class = Portage::Ucp::Instagram::ApiError
      end
    end
  end
end
