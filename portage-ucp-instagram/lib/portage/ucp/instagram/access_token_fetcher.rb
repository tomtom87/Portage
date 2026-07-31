require "net/http"
require "json"

module Portage
  module Ucp
    module Instagram
      # Exchanges a short-lived user/page access token for a long-lived one
      # (~60 days) via Graph API's `fb_exchange_token` grant.
      #
      # Doesn't handle the *initial* Business Login consent redirect that
      # produces the short-lived token in the first place (that's an
      # interactive, one-time setup step outside this gem's scope) — only
      # the long-lived exchange a server needs to avoid re-running consent
      # every few hours. Meta doesn't support refreshing past the ~60-day
      # long-lived token's own expiry — re-running consent is the only way
      # past that, there's no refresh_token here the way Etsy/Shopify have.
      class AccessTokenFetcher
        Result = Struct.new(:access_token, :expires_in, keyword_init: true)

        def initialize(client_id:, client_secret:, short_lived_token:, api_version: Client::DEFAULT_API_VERSION)
          @client_id = client_id
          @client_secret = client_secret
          @short_lived_token = short_lived_token
          @api_version = api_version
        end

        def fetch
          params = { grant_type: "fb_exchange_token", client_id: @client_id, client_secret: @client_secret,
                     fb_exchange_token: @short_lived_token }
          uri = URI("https://graph.facebook.com/#{@api_version}/oauth/access_token?#{URI.encode_www_form(params)}")

          response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(Net::HTTP::Get.new(uri)) }
          body = JSON.parse(response.body)
          raise Portage::Ucp::Instagram::Error, "token exchange failed: #{body}" unless response.is_a?(Net::HTTPSuccess)

          Result.new(access_token: body["access_token"], expires_in: body["expires_in"])
        end
      end
    end
  end
end
