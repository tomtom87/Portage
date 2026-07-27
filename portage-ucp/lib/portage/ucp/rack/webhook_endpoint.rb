require "json"
require "openssl"
require "rack"

module Portage
  module Ucp
    module Rack
      # Receives backend order-lifecycle webhooks (§11). Verifies the HMAC
      # signature against the raw body *before* parsing anything, per the
      # standard webhook guardrail: never trust a payload before you've
      # authenticated it. Normalizes to a Portage::Ucp::Order and hands off to a
      # consumer-supplied `on_order_event` callback — the gem doesn't assume
      # anything about how the consumer stores or reacts to order events.
      class WebhookEndpoint
        def initialize(secret:, on_order_event:, signature_header: "HTTP_X_UCP_SIGNATURE")
          @secret = secret
          @on_order_event = on_order_event
          @signature_header = signature_header
        end

        def call(env)
          request = ::Rack::Request.new(env)
          return respond(404, error: "not_found") unless request.post?

          body = request.body.read
          return respond(401, error: "invalid_signature") unless valid_signature?(body, env[@signature_header])

          handle_order_event(body)
        end

        private

        def handle_order_event(body)
          payload = JSON.parse(body, symbolize_names: true)
          @on_order_event.call(Portage::Ucp::Order.new(**payload))
          respond(200, ok: true)
        rescue JSON::ParserError, ArgumentError
          respond(400, error: "bad_request")
        end

        def valid_signature?(body, signature)
          return false unless signature

          expected = OpenSSL::HMAC.hexdigest("SHA256", @secret, body)
          ::Rack::Utils.secure_compare(expected, signature)
        end

        def respond(status, body)
          [status, { "content-type" => "application/json" }, [JSON.generate(body)]]
        end
      end
    end
  end
end
