require "net/http"
require "json"
require "uri"
require_relative "connection"

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
        # Net::HTTP's own defaults (open: 60s, read: 60s) are sized for a
        # human waiting on a browser tab, not an agent loop mid-checkout —
        # a hung upstream would otherwise tie up a call for a full minute
        # before Support::Retry (or the caller) even gets a chance to react.
        # Mirrors Check#get's own explicit open_timeout: 5, read_timeout: 5
        # precedent; read gets more room here since a slow catalog/checkout
        # response is common and legitimate, where Check is just a fast
        # existence probe.
        DEFAULT_OPEN_TIMEOUT = 5
        DEFAULT_READ_TIMEOUT = 30

        private

        # @param basic_auth [Array(String, String), nil] user/password pair
        #   for APIs authorized with HTTP Basic rather than a header token
        #   (e.g. WooCommerce's Admin consumer key/secret).
        # @param raw [Boolean] return the Net::HTTPResponse itself instead of
        #   the parsed body — for callers that need response headers (e.g.
        #   WooCommerce's Cart-Token session threading). They call #parse!
        #   themselves once they're done reading headers.
        # @param open_timeout [Numeric] seconds to wait for the TCP
        #   connection itself; see DEFAULT_OPEN_TIMEOUT.
        # @param read_timeout [Numeric] seconds to wait for each read off an
        #   already-open connection; see DEFAULT_READ_TIMEOUT.
        # @param route [Symbol] docs/plans/proxy-support.md's proxy route —
        #   every included adapter gem talks to a platform admin API here,
        #   so :platform is the sensible default; a core caller with a
        #   different traffic shape (e.g. Confirmer::Webhook's out-of-band
        #   notification) passes its own.
        def json_request(http_method, uri, body: nil, headers: {}, basic_auth: nil, raw: false,
                         open_timeout: DEFAULT_OPEN_TIMEOUT, read_timeout: DEFAULT_READ_TIMEOUT, route: :platform)
          uri = URI(uri.to_s)
          request = http_method.new(uri)
          request.basic_auth(*basic_auth) if basic_auth
          headers.each { |name, value| request[name] = value }
          request["Content-Type"] ||= "application/json"
          request.body = JSON.generate(body) if body

          response = Portage::Ucp::Support::Connection.start(
            uri, route: route, open_timeout: open_timeout, read_timeout: read_timeout
          ) { |http| http.request(request) }
          raw ? response : parse!(response)
        end

        # An empty body is `{}` rather than a parse error: several APIs
        # answer a successful DELETE with 204 and no content at all.
        def parse!(response)
          parsed = response.body.nil? || response.body.empty? ? {} : JSON.parse(response.body)
          return parsed if response.is_a?(Net::HTTPSuccess)

          status = response.code.to_i
          # 409 means "you lost a race with a concurrent write" the same way
          # on every REST platform behind this module — normalized here to
          # Portage::Ucp::ConflictError rather than each gem's own ApiError,
          # since it's cross-cutting, not platform-specific (see errors.rb).
          raise Portage::Ucp::ConflictError, "conflict (409): #{parsed}" if status == 409

          raise api_error_class.new(status, parsed, retry_after: response["Retry-After"])
        end

        def api_error_class
          raise Portage::Ucp::NotImplementedError, "#{self.class} must implement #api_error_class"
        end
      end
    end
  end
end
