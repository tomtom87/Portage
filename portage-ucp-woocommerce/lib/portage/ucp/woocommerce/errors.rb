module Portage
  module Ucp
    module WooCommerce
      class Error < StandardError; end

      # Raised for any non-2xx response from either the Admin REST API (v3,
      # Basic Auth) or the Store API (v1, cart-token session) — both surface
      # errors the same way: a non-2xx status with a JSON `{code, message}`
      # body (`rest_*` codes on the Admin side, `woocommerce_rest_*`/
      # `woocommerce_store_api_*` on the Store side).
      class ApiError < Error
        include Portage::Ucp::Support::ApiError

        private

        def detail(body)
          body["message"] || body
        end
      end
    end
  end
end
