require "net/http"
require "json"

module Portage
  module Ucp
    module Wix
      # Exchanges a Wix app's client_id/client_secret (plus the target site's
      # instance_id) for a site-scoped access token via Wix's OAuth
      # client_credentials grant.
      #
      # Wix apps authenticate server-to-server the same way Shopify custom
      # apps now do: no static, copy-once token — client_id/client_secret get
      # exchanged (and re-exchanged once expired) for the real access_token
      # used by Portage::Ucp::Wix::Client. The one addition versus Shopify is
      # `instance_id`: Wix's OAuth endpoint is one shared host
      # (www.wixapis.com) serving every site, so the token has to be scoped
      # to a specific site's app instance at exchange time rather than via a
      # per-shop subdomain.
      class AccessTokenFetcher
        include Portage::Ucp::Support::TokenExchange

        Result = Struct.new(:access_token, :expires_in, keyword_init: true)

        ENDPOINT = "https://www.wixapis.com/oauth2/token".freeze

        def initialize(client_id:, client_secret:, instance_id:)
          @client_id = client_id
          @client_secret = client_secret
          @instance_id = instance_id
        end

        def fetch
          body = exchange(ENDPOINT,
                          { grant_type: "client_credentials", client_id: @client_id,
                            client_secret: @client_secret, instance_id: @instance_id },
                          error_class: Portage::Ucp::Wix::Error)
          Result.new(access_token: body["access_token"], expires_in: body["expires_in"])
        end
      end
    end
  end
end
