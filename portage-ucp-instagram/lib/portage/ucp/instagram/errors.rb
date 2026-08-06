module Portage
  module Ucp
    module Instagram
      class Error < StandardError; end

      # Raised for any non-2xx response from Meta's Graph API
      # (`graph.facebook.com`) — a non-2xx status with a JSON
      # `{error: {message, type, code}}` body.
      class ApiError < Error
        include Portage::Ucp::Support::ApiError

        private

        # Not just "Instagram": the same client and errors cover Facebook
        # Shops, since both sit on one Meta Graph API surface.
        def api_label = "Instagram/Graph"

        def detail(body)
          body.dig("error", "message") || body
        end
      end
    end
  end
end
