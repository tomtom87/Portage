require "net/http"
require "json"

module Portage
  module Ucp
    module WooCommerce
      # Minimal REST client over a WooCommerce site's two distinct APIs.
      #
      # Deliberately plain Net::HTTP, not the `woocommerce-api` gem — a
      # generic adapter that any Ruby app can drop in only needs a site URL
      # and a pair of keys, no framework coupling, trivially stubbable with
      # WebMock.
      #
      # Like Shopify's Admin/Storefront split, WooCommerce has two separate
      # APIs with two separate auth models:
      #
      # - Admin REST API (`/wp-json/wc/v3`): store-owner Basic Auth via a
      #   static consumer_key/consumer_secret pair generated once in
      #   wp-admin. No OAuth exchange, no expiry — unlike Shopify/Wix, there
      #   is no Portage::Ucp::WooCommerce::AccessTokenFetcher because there's
      #   nothing to exchange.
      # - Store API (`/wp-json/wc/store/v1`): the public, unauthenticated
      #   cart/checkout API WooCommerce Blocks itself uses. It's session-
      #   based rather than token-based: the *first* request gets back a
      #   `Cart-Token` response header identifying an anonymous cart, which
      #   must be resent as a `Cart-Token` request header on every
      #   subsequent call to stay on the same cart. State-changing calls
      #   (POST/PUT/DELETE) also require a `Nonce` header, sourced the same
      #   way from an earlier response. This client tracks both headers
      #   in-instance so callers don't have to.
      class Client
        def initialize(site_url:, consumer_key:, consumer_secret:)
          @site_url = site_url.chomp("/")
          @consumer_key = consumer_key
          @consumer_secret = consumer_secret
          @cart_token = nil
          @nonce = nil
        end

        attr_reader :cart_token

        def admin_get(path)
          admin_request(Net::HTTP::Get, path)
        end

        def admin_post(path, body = {})
          admin_request(Net::HTTP::Post, path, body)
        end

        def store_get(path)
          store_request(Net::HTTP::Get, path)
        end

        def store_post(path, body = {})
          store_request(Net::HTTP::Post, path, body)
        end

        def store_delete(path)
          store_request(Net::HTTP::Delete, path)
        end

        private

        def admin_request(http_method, path, body = nil)
          req = http_method.new(URI("#{@site_url}/wp-json/wc/v3#{path}"))
          req.basic_auth(@consumer_key, @consumer_secret)
          perform(req, body)
        end

        # Threads `Cart-Token` on every call (once one's been seen) and
        # `Nonce` on writes — see the class-level comment. Both are
        # refreshed from whatever the response hands back, since WooCommerce
        # can rotate the nonce between requests.
        def store_request(http_method, path, body = nil)
          req = http_method.new(URI("#{@site_url}/wp-json/wc/store/v1#{path}"))
          req["Cart-Token"] = @cart_token if @cart_token
          req["Nonce"] = @nonce if @nonce && http_method != Net::HTTP::Get
          response = perform(req, body, raw: true)

          @cart_token = response["Cart-Token"] if response["Cart-Token"]
          @nonce = response["Nonce"] if response["Nonce"]
          parse!(response)
        end

        def perform(req, body, raw: false)
          req["Content-Type"] = "application/json"
          req.body = JSON.generate(body) if body

          uri = req.uri
          response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") { |http| http.request(req) }
          return response if raw

          parse!(response)
        end

        def parse!(response)
          parsed = response.body.nil? || response.body.empty? ? {} : JSON.parse(response.body)
          unless response.is_a?(Net::HTTPSuccess)
            raise Portage::Ucp::WooCommerce::ApiError.new(response.code.to_i, parsed)
          end

          parsed
        end
      end
    end
  end
end
