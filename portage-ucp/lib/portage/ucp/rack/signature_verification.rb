require "json"
require "rack"

module Portage
  module Ucp
    module Rack
      # Generic Rack middleware wrapping an inbound MCP/UCP endpoint (however
      # the consumer mounts it, §7.3 — this gem stays deployment-agnostic):
      # verifies the RFC 9421 HTTP Message Signature over the request
      # (Security::Signature, §22) before the wrapped app ever sees it.
      #
      # Verify-before-parse (same posture as Rack::WebhookEndpoint): the body
      # is read and handed to Signature.verify! as raw bytes, never parsed
      # as JSON here. Only on success is it rewound for the wrapped app to
      # read and parse (as JSON-RPC) itself.
      class SignatureVerification
        # @param app [#call] the wrapped Rack app (e.g. the MCP transport's
        #   own Rack endpoint)
        # @param trusted_keys [Array<Hash>, #call] see Security::Signature
        # @param required_components [Array<String>] forwarded to
        #   Security::Signature.verify!
        # @param max_age [Integer, nil] forwarded to Security::Signature.verify!
        # @param logger [Logger]
        def initialize(app, trusted_keys:, required_components: %w[@method @authority @path idempotency-key],
                       max_age: 300, logger: Portage::Ucp.configuration.logger)
          @app = app
          @trusted_keys = trusted_keys
          @required_components = required_components
          @max_age = max_age
          @logger = logger
        end

        def call(env)
          request = ::Rack::Request.new(env)
          body = request.body.read
          request.body.rewind

          Portage::Ucp::Security::Signature.verify!(
            method: request.request_method, authority: request.host_with_port, path: request.path,
            query: request.query_string.empty? ? nil : "?#{request.query_string}",
            headers: headers_from(env), body: body, trusted_keys: @trusted_keys,
            required_components: @required_components, max_age: @max_age
          )

          @app.call(env)
        rescue Portage::Ucp::Security::SignatureError => e
          reject(e)
        end

        private

        # RFC 9421-covered headers reach us as Rack's HTTP_* env entries
        # (except content-type/content-length, which Rack exposes
        # unprefixed) — normalize both into the lower-case, hyphenated form
        # Security::Signature expects.
        def headers_from(env)
          env.each_with_object({}) do |(key, value), headers|
            if key.start_with?("HTTP_")
              headers[key.delete_prefix("HTTP_").tr("_", "-").downcase] = value
            elsif %w[CONTENT_TYPE CONTENT_LENGTH].include?(key)
              headers[key.tr("_", "-").downcase] = value
            end
          end
        end

        def reject(error)
          Portage::Ucp::Observability.log(@logger, "signature_verification_rejected",
                                          reason: error.class.name.split("::").last)
          [401, { "content-type" => "application/json" }, [JSON.generate(error: "invalid_signature")]]
        end
      end
    end
  end
end
