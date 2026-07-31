require "net/http"
require "json"

module Portage
  module Ucp
    module Magento
      # Minimal REST client over a Magento/Adobe Commerce site's `/rest/V1`
      # API.
      #
      # Deliberately plain Net::HTTP, not the Magento PHP SDK (there isn't a
      # Ruby one) — a generic adapter that any Ruby app can drop in only
      # needs a base URL and a bearer token, no framework coupling,
      # trivially stubbable with WebMock.
      #
      # Like Shopify's Admin/Storefront split and WooCommerce's Admin/Store
      # API split, Magento's REST surface has two effective auth tiers under
      # the same `/rest/V1` path:
      #
      # - Admin-token calls (catalog, order): require a Bearer token minted
      #   from admin credentials (see
      #   Portage::Ucp::Magento::AccessTokenFetcher) or a pre-generated
      #   Integration token.
      # - Guest-cart calls (cart, checkout): Magento's guest-cart endpoints
      #   (`/guest-carts/*`) are anonymous by design — no token at all,
      #   identified purely by the masked cart id in the URL.
      class Client
        def initialize(base_url:, admin_token: nil)
          @base_url = base_url.chomp("/")
          @admin_token = admin_token
        end

        def admin_get(path)
          admin_request(Net::HTTP::Get, path)
        end

        def admin_post(path, body = {})
          admin_request(Net::HTTP::Post, path, body)
        end

        def guest_get(path)
          guest_request(Net::HTTP::Get, path)
        end

        def guest_post(path, body = {})
          guest_request(Net::HTTP::Post, path, body)
        end

        def guest_delete(path)
          guest_request(Net::HTTP::Delete, path)
        end

        private

        def admin_request(http_method, path, body = nil)
          raise ArgumentError, "Portage::Ucp::Magento::Client requires admin_token for this call" unless @admin_token

          req = http_method.new(URI("#{@base_url}/rest/V1#{path}"))
          req["Authorization"] = "Bearer #{@admin_token}"
          perform(req, body)
        end

        def guest_request(http_method, path, body = nil)
          req = http_method.new(URI("#{@base_url}/rest/V1#{path}"))
          perform(req, body)
        end

        def perform(req, body)
          req["Content-Type"] = "application/json"
          req.body = JSON.generate(body) if body

          uri = req.uri
          response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") { |http| http.request(req) }
          parsed = response.body.nil? || response.body.empty? ? {} : JSON.parse(response.body)
          raise Portage::Ucp::Magento::ApiError.new(response.code.to_i, parsed) unless response.is_a?(Net::HTTPSuccess)

          parsed
        end
      end
    end
  end
end
