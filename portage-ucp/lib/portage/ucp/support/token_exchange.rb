require "net/http"
require "json"
require "uri"

module Portage
  module Ucp
    module Support
      # The POST-JSON-and-parse half of every adapter gem's
      # AccessTokenFetcher. What each gem keeps is the part that genuinely
      # differs: its endpoint, its grant payload, and how it maps the
      # response body onto its own Result struct (Magento reports no
      # `expires_in` at all; Etsy rotates the refresh_token on every use).
      #
      # Separate from Support::HttpClient because the failure mode is
      # different: a token exchange has no ApiError/status contract to honor
      # — a non-2xx here means "these credentials don't work", which is the
      # gem's plain Error, not something a caller retries on a 404.
      module TokenExchange
        private

        # @param error_class [Class] the gem's own Error
        # @param description [String] what failed, e.g. "token refresh failed"
        # @param form [Boolean] send the grant as form-encoded rather than
        #   JSON. OAuth 2.0 specifies form encoding for the token endpoint and
        #   Shopify follows it to the letter; the others accept JSON, so JSON
        #   stays the default rather than churn three working callers.
        # @return [Hash, String] the parsed response body
        def exchange(endpoint, payload, error_class:, description: "token exchange failed", form: false)
          uri = URI(endpoint)
          request = Net::HTTP::Post.new(uri)
          request["Content-Type"] = form ? "application/x-www-form-urlencoded" : "application/json"
          request.body = form ? URI.encode_www_form(payload) : JSON.generate(payload)

          response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") { |http| http.request(request) }
          body = JSON.parse(response.body)
          raise error_class, "#{description}: #{body}" unless response.is_a?(Net::HTTPSuccess)

          body
        end
      end
    end
  end
end
