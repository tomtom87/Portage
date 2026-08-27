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
      #
      # Emits Observability events (§12) directly via `logger:` rather than a
      # new config.event_sink seam (§23 step 5): this endpoint is a plain Rack
      # app, not built through Mcp::Server.build, so it never runs inside an
      # MCP request and `mcp`'s own around_request/instrumentation_callback
      # hooks can't see it — the same reason CheckoutState (§23 step 3) needed
      # a logger threaded to it, not a reason to invent a second config
      # option: `logger:` already exists on Portage::Ucp.configuration and
      # every other collaborator that logs takes it the same way.
      class WebhookEndpoint
        def initialize(secret:, on_order_event:, signature_header: "HTTP_X_UCP_SIGNATURE",
                       logger: Portage::Ucp.configuration.logger)
          @secret = secret
          @on_order_event = on_order_event
          @signature_header = signature_header
          @logger = logger
        end

        def call(env)
          request = ::Rack::Request.new(env)
          return respond(404, error: "not_found") unless request.post?

          body = request.body.read
          unless valid_signature?(body, env[@signature_header])
            Portage::Ucp::Observability.log(@logger, "order_webhook_rejected", reason: "invalid_signature")
            return respond(401, error: "invalid_signature")
          end

          handle_order_event(body)
        end

        private

        def handle_order_event(body)
          payload = JSON.parse(body, symbolize_names: true)
          order = Portage::Ucp::Order.new(**payload)
          Portage::Ucp::Observability.log(@logger, "order_webhook_received", order_id: order.id,
                                                                             checkout_id: order.checkout_id)
          @on_order_event.call(order)
          respond(200, ok: true)
        rescue JSON::ParserError, ArgumentError
          Portage::Ucp::Observability.log(@logger, "order_webhook_rejected", reason: "bad_request")
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
