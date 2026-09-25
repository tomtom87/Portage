require "json"
require "openssl"
require "rack"
require_relative "forwarded_request"

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
      #
      # Phase 3 of docs/plans/proxy-support.md: `trusted_proxies:` lets a
      # consumer behind a reverse proxy get the real client IP into its own
      # logs/`on_order_event` handling (`ForwardedRequest#client_ip`, fail-
      # closed with no config change otherwise) and, when
      # `passthrough_headers:` is also set, forwards that request's
      # allowlisted headers (trusted peer only) to any outbound call
      # `on_order_event` makes via Support::Connection, through the same
      # fiber-local Support::PassthroughContext CallEndpoint uses — cleared
      # again once `on_order_event` returns.
      class WebhookEndpoint
        # @param trusted_proxies [Array<String>] CIDRs of the consumer's own
        #   reverse proxy/load balancer — see ForwardedRequest.
        # @param passthrough_headers [Array<String>] inbound header names to
        #   forward to outbound calls made from `on_order_event`, from a
        #   trusted peer only. Never a protected header (raises at
        #   construction time — see ForwardedRequest.validate_passthrough!).
        # @param passthrough_forwarded ["append", "replace", "drop"] see
        #   Support::PassthroughContext.
        def initialize(secret:, on_order_event:, signature_header: "HTTP_X_UCP_SIGNATURE",
                       logger: Portage::Ucp.configuration.logger, trusted_proxies: [],
                       passthrough_headers: [], passthrough_forwarded: "drop")
          @secret = secret
          @on_order_event = on_order_event
          @signature_header = signature_header
          @logger = logger
          @trusted_proxies = trusted_proxies
          @passthrough_headers = passthrough_headers
          @passthrough_forwarded = passthrough_forwarded
          ForwardedRequest.validate_passthrough!(@passthrough_headers)
        end

        def call(env)
          request = ::Rack::Request.new(env)
          return respond(404, error: "not_found") unless request.post?

          forwarded = ForwardedRequest.new(request, trusted_proxies: @trusted_proxies)
          body = request.body.read
          unless valid_signature?(body, env[@signature_header])
            Portage::Ucp::Observability.log(@logger, "order_webhook_rejected", reason: "invalid_signature",
                                                                               client_ip: forwarded.client_ip)
            return respond(401, error: "invalid_signature")
          end

          handle_order_event(body, forwarded)
        end

        private

        def handle_order_event(body, forwarded)
          payload = JSON.parse(body, symbolize_names: true)
          order = Portage::Ucp::Order.new(**payload)
          Portage::Ucp::Observability.log(@logger, "order_webhook_received", order_id: order.id,
                                                                             checkout_id: order.checkout_id,
                                                                             client_ip: forwarded.client_ip)
          with_passthrough(forwarded) { @on_order_event.call(order) }
          respond(200, ok: true)
        rescue JSON::ParserError, ArgumentError
          Portage::Ucp::Observability.log(@logger, "order_webhook_rejected", reason: "bad_request",
                                                                             client_ip: forwarded.client_ip)
          respond(400, error: "bad_request")
        end

        def with_passthrough(forwarded, &)
          return yield unless forwarded.peer_trusted? && @passthrough_headers.any?

          headers = forwarded.passthrough_headers(@passthrough_headers)
          Portage::Ucp::Support::PassthroughContext.with(headers: headers, forwarded: @passthrough_forwarded,
                                                         chain_entry: forwarded.client_ip, &)
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
