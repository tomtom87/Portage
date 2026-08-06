require "net/http"
require "json"

module Portage
  module Ucp
    module Magento
      # Exchanges Magento admin credentials for a bearer token via
      # `/rest/V1/integration/admin/token`.
      #
      # Unlike Shopify/Wix's client_credentials grant, this is a plain
      # username/password exchange (Magento's third-party OAuth1 Integration
      # flow is the alternative, but that signs every request rather than
      # handing back a bearer token, which doesn't fit this gem's plain-
      # Net::HTTP posture). Also unlike Shopify/Wix, the endpoint returns a
      # bare token string with no `expires_in` — Magento's default admin
      # token lifetime is a store-config value (`admin/security/session_
      # lifetime`-adjacent, but token-specific), not something this response
      # reports, so callers need their own refresh-on-401 strategy rather
      # than a reported expiry.
      class AccessTokenFetcher
        include Portage::Ucp::Support::TokenExchange

        Result = Struct.new(:access_token, keyword_init: true)

        def initialize(base_url:, username:, password:)
          @base_url = base_url.chomp("/")
          @username = username
          @password = password
        end

        def fetch
          body = exchange("#{@base_url}/rest/V1/integration/admin/token",
                          { username: @username, password: @password },
                          error_class: Portage::Ucp::Magento::Error)
          Result.new(access_token: body)
        end
      end
    end
  end
end
