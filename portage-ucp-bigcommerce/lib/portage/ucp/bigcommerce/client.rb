require "net/http"
require "json"

module Portage
  module Ucp
    module BigCommerce
      # Minimal REST client over a BigCommerce store's Admin APIs.
      #
      # Deliberately plain Net::HTTP, not the `bigcommerce_api` gem — a
      # generic adapter that any Ruby app can drop in only needs a store hash
      # and a pair of static API account credentials, no framework coupling,
      # trivially stubbable with WebMock.
      #
      # Unlike Shopify/Wix, there's no Portage::Ucp::BigCommerce::AccessTokenFetcher:
      # a store-owner-created API account (Settings → API → Create API Account)
      # hands back a client_id/access_token pair with no expiry, same static-
      # credential posture as Portage::Ucp::WooCommerce::Client. The separate
      # OAuth authorization-code flow BigCommerce uses for public Marketplace
      # apps is a different concern, out of scope here.
      #
      # BigCommerce splits its Admin surface across two API generations under
      # the same host: catalog/carts/checkouts live on v3, Orders is still v2
      # only — both are exposed here rather than picking one.
      #
      # Completing a checkout also requires the separate Payments API, which
      # lives on a *different* host (`payments.bigcommerce.com`) and is
      # authorized with a short-lived payment access token rather than the
      # store's own API credentials — see #process_payment.
      class Client
        include Portage::Ucp::Support::HttpClient

        def initialize(store_hash:, client_id:, access_token:)
          @store_hash = store_hash
          @client_id = client_id
          @access_token = access_token
        end

        def v2_get(path)
          admin_request(Net::HTTP::Get, "v2", path)
        end

        def v2_post(path, body = {})
          admin_request(Net::HTTP::Post, "v2", path, body)
        end

        def v3_get(path)
          admin_request(Net::HTTP::Get, "v3", path)
        end

        def v3_post(path, body = {})
          admin_request(Net::HTTP::Post, "v3", path, body)
        end

        def v3_put(path, body = {})
          admin_request(Net::HTTP::Put, "v3", path, body)
        end

        def v3_delete(path)
          admin_request(Net::HTTP::Delete, "v3", path)
        end

        # Authorized with the payment access token minted by
        # POST /v3/payments/access_tokens (see Adapter#submit_checkout), not
        # the store's own client_id/access_token — BigCommerce scopes a
        # payment token to a single order for a single completion attempt.
        def process_payment(payment_access_token:, order_id:, payment_instrument:)
          json_request(
            Net::HTTP::Post, "https://payments.bigcommerce.com/stores/#{@store_hash}/payments",
            body: { payment: { instrument: payment_instrument }, order: { id: order_id } },
            headers: { "Authorization" => payment_access_token,
                       "Content-Type" => "application/vnd.bc.payments.v1+json",
                       "Accept" => "application/vnd.bc.payments.v1+json" }
          )
        end

        private

        def admin_request(http_method, version, path, body = nil)
          json_request(http_method, "https://api.bigcommerce.com/stores/#{@store_hash}/#{version}#{path}",
                       body: body,
                       headers: { "X-Auth-Client" => @client_id, "X-Auth-Token" => @access_token,
                                  "Accept" => "application/json" })
        end

        def api_error_class = Portage::Ucp::BigCommerce::ApiError
      end
    end
  end
end
