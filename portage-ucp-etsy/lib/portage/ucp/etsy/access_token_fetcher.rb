require "net/http"
require "json"

module Portage
  module Ucp
    module Etsy
      # Exchanges a refresh_token for a new access_token via Etsy's OAuth2
      # `/v3/public/oauth/token` endpoint.
      #
      # Doesn't handle the *initial* authorization-code exchange (that needs
      # a PKCE code_verifier from an interactive consent redirect, which is
      # a one-time setup step outside this gem's scope) — only the refresh
      # step a long-running server needs repeatedly. Unlike Shopify/Wix/
      # Magento, Etsy **rotates** the refresh_token on every use: the
      # response's `refresh_token` is a new value, and the one passed in
      # becomes invalid immediately, so callers must persist the returned
      # one before the next refresh, not just the access_token.
      class AccessTokenFetcher
        include Portage::Ucp::Support::TokenExchange

        Result = Struct.new(:access_token, :refresh_token, :expires_in, keyword_init: true)

        ENDPOINT = "https://api.etsy.com/v3/public/oauth/token".freeze

        def initialize(client_id:, refresh_token:)
          @client_id = client_id
          @refresh_token = refresh_token
        end

        def fetch
          body = exchange(ENDPOINT,
                          { grant_type: "refresh_token", client_id: @client_id, refresh_token: @refresh_token },
                          error_class: Portage::Ucp::Etsy::Error, description: "token refresh failed")
          Result.new(access_token: body["access_token"], refresh_token: body["refresh_token"],
                     expires_in: body["expires_in"])
        end
      end
    end
  end
end
