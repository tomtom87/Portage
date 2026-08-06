require "net/http"
require "json"
require "uri"

module Portage
  module Ucp
    module Support
      # The plain Net::HTTP + JSON request/response handling every adapter
      # gem's Client repeated. Deliberately Net::HTTP rather than a per-
      # platform vendor gem: a generic adapter any Ruby app can drop in
      # shouldn't drag in framework coupling, and it stays trivially
      # stubbable with WebMock.
      #
      # An including Client supplies two things — its auth headers and paths
      # (by building the uri/headers it passes to #json_request) and
      # #api_error_class, the gem's own ApiError to raise on a non-2xx.
      module HttpClient
        private

        # @param basic_auth [Array(String, String), nil] user/password pair
        #   for APIs authorized with HTTP Basic rather than a header token
        #   (e.g. WooCommerce's Admin consumer key/secret).
        # @param raw [Boolean] return the Net::HTTPResponse itself instead of
        #   the parsed body — for callers that need response headers (e.g.
        #   WooCommerce's Cart-Token session threading). They call #parse!
        #   themselves once they're done reading headers.
        def json_request(http_method, uri, body: nil, headers: {}, basic_auth: nil, raw: false)
          uri = URI(uri.to_s)
          request = http_method.new(uri)
          request.basic_auth(*basic_auth) if basic_auth
          headers.each { |name, value| request[name] = value }
          request["Content-Type"] ||= "application/json"
          request.body = JSON.generate(body) if body

          response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") { |http| http.request(request) }
          raw ? response : parse!(response)
        end

        # An empty body is `{}` rather than a parse error: several APIs
        # answer a successful DELETE with 204 and no content at all.
        def parse!(response)
          parsed = response.body.nil? || response.body.empty? ? {} : JSON.parse(response.body)
          raise api_error_class.new(response.code.to_i, parsed) unless response.is_a?(Net::HTTPSuccess)

          parsed
        end

        def api_error_class
          raise Portage::Ucp::NotImplementedError, "#{self.class} must implement #api_error_class"
        end
      end
    end
  end
end
