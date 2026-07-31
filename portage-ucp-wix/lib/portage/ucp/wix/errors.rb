module Portage
  module Ucp
    module Wix
      class Error < StandardError; end

      # Raised for any non-2xx response from a Wix REST call. Unlike Shopify's
      # GraphQL/userErrors split, Wix's REST APIs report both transport-level
      # rejections (bad auth, malformed request) and business rejections
      # (e.g. "line item not found") the same way — a non-2xx status with a
      # JSON error body — so one error class covers both.
      class ApiError < Error
        attr_reader :status, :body

        def initialize(status, body)
          @status = status
          @body = body
          super("Wix API error (#{status}): #{body['message'] || body}")
        end
      end
    end
  end
end
