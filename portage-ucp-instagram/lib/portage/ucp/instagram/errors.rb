module Portage
  module Ucp
    module Instagram
      class Error < StandardError; end

      # Raised for any non-2xx response from Meta's Graph API
      # (`graph.facebook.com`) — a non-2xx status with a JSON
      # `{error: {message, type, code}}` body.
      class ApiError < Error
        attr_reader :status, :body

        def initialize(status, body)
          @status = status
          @body = body
          super("Instagram/Graph API error (#{status}): #{body.dig('error', 'message') || body}")
        end
      end
    end
  end
end
