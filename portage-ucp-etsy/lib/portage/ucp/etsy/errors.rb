module Portage
  module Ucp
    module Etsy
      class Error < StandardError; end

      # Raised for any non-2xx response from Etsy's Open API v3
      # (`api.etsy.com/v3/application`) — a non-2xx status with a JSON
      # `{error, error_description}` (OAuth) or `{error}` (REST) body.
      class ApiError < Error
        attr_reader :status, :body

        def initialize(status, body)
          @status = status
          @body = body
          super("Etsy API error (#{status}): #{body['error_description'] || body['error'] || body}")
        end
      end
    end
  end
end
