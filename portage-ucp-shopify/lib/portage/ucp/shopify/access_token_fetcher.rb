require "net/http"
require "json"

module Portage
  module Ucp
    module Shopify
      # Exchanges a custom app's client_id/client_secret for an Admin API
      # access token via Shopify's OAuth client_credentials grant.
      #
      # Shopify moved custom apps off static, copy-once tokens shown in the
      # admin UI: creating a custom app now only exposes a client_id and
      # client_secret, and the actual admin_access_token used by
      # Portage::Ucp::Shopify::Client must be fetched (and re-fetched once
      # expired) from POST /admin/oauth/access_token.
      class AccessTokenFetcher
        include Portage::Ucp::Support::TokenExchange

        Result = Struct.new(:access_token, :expires_in, keyword_init: true)

        def initialize(shop_domain:, client_id:, client_secret:)
          @shop_domain = shop_domain
          @client_id = client_id
          @client_secret = client_secret
        end

        def fetch
          body = exchange("https://#{@shop_domain}/admin/oauth/access_token",
                          { grant_type: "client_credentials", client_id: @client_id,
                            client_secret: @client_secret },
                          error_class: Portage::Ucp::Shopify::Error, form: true)
          Result.new(access_token: body["access_token"], expires_in: body["expires_in"])
        end
      end
    end
  end
end
