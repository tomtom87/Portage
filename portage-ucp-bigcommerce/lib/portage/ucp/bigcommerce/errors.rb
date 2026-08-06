module Portage
  module Ucp
    module BigCommerce
      class Error < StandardError; end

      # Raised for any non-2xx response from the Admin API (v2 Orders, v3
      # Catalog/Carts/Checkouts) or the Payments API. BigCommerce's error body
      # shape isn't uniform across API generations — v3 responses carry a
      # `title`, v2 responses (and some v3 validation failures) carry an
      # `errors` array/hash instead — so this tries both rather than assuming
      # one.
      class ApiError < Error
        include Portage::Ucp::Support::ApiError

        private

        def detail(body)
          body["title"] || body["errors"] || body
        end
      end
    end
  end
end
