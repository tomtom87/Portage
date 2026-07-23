require "json"
require "rack"

module UcpMcp
  module Rack
    # Rack app serving GET /.well-known/ucp — the signed UCP discovery document.
    # Mount it however suits the consumer's app (in-process or standalone, §7.3);
    # this gem makes no assumption about host framework or process model.
    class ManifestEndpoint
      # @param allow_insecure [Boolean] TLS termination is the consumer's job
      #   (§9), so by default this refuses to serve payment-handler
      #   declarations over plaintext HTTP rather than silently leaking them.
      #   Set true only for local development over http://localhost.
      def initialize(manifest:, allow_insecure: false)
        @manifest = manifest
        @allow_insecure = allow_insecure
      end

      def call(env)
        request = ::Rack::Request.new(env)
        return not_found unless request.get?

        payload = @manifest.to_h
        return insecure_rejected if payment_handlers_over_plaintext?(payload, request)

        [200, { "content-type" => "application/json" }, [JSON.generate(payload)]]
      end

      private

      def payment_handlers_over_plaintext?(payload, request)
        return false if @allow_insecure || request.ssl?

        !Array(payload[:payment_handlers]).empty?
      end

      def not_found
        [404, { "content-type" => "application/json" }, [JSON.generate(error: "not_found")]]
      end

      def insecure_rejected
        [496, { "content-type" => "application/json" },
         [JSON.generate(error: "payment_handlers require TLS — refusing to serve over plaintext HTTP")]]
      end
    end
  end
end
