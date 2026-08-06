module Portage
  module Ucp
    module Magento
      class Error < StandardError; end

      # Raised for any non-2xx response from Magento's REST API (`/rest/V1`)
      # — both the admin-token side (catalog, order) and the anonymous
      # guest-cart side (cart, checkout) report errors the same way: a
      # non-2xx status with a JSON `{message, parameters}` body.
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
