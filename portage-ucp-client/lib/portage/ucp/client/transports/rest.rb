require "faraday"
require "json"
require "uri"
require_relative "../errors"
require_relative "ucp_wire_shape"

module Portage
  module Ucp
    module Client
      module Transports
        # Connects to a UCP server's REST service (2026-08-25's core
        # transport) — the same Session seam as Http, a different wire. REST
        # bodies are the bare capability object, so this reuses UcpWireShape
        # to build the MCP body and drops the capability wrapper key; ids go
        # in the path; `meta` becomes headers instead of body fields.
        class Rest
          include UcpWireShape

          # action => [verb, path (`{id}` is the action's identifying
          # argument), wrapper key of the body — nil for no body].
          ROUTES = {
            "search_catalog" => ["POST", "/catalog/search", "catalog"],
            "lookup_catalog" => ["POST", "/catalog/lookup", "catalog"],
            "get_product" => ["POST", "/catalog/product", "catalog"],
            "create_cart" => ["POST", "/carts", "cart"],
            "get_cart" => ["GET", "/carts/{id}", nil],
            "update_cart" => ["PUT", "/carts/{id}", "cart"],
            "cancel_cart" => ["POST", "/carts/{id}/cancel", nil],
            "create_checkout" => ["POST", "/checkout-sessions", "checkout"],
            "get_checkout" => ["GET", "/checkout-sessions/{id}", nil],
            "update_checkout" => ["PUT", "/checkout-sessions/{id}", "checkout"],
            "complete_checkout" => ["POST", "/checkout-sessions/{id}/complete", "checkout"],
            "cancel_checkout" => ["POST", "/checkout-sessions/{id}/cancel", nil],
            "get_order" => ["GET", "/orders/{id}", nil]
          }.freeze

          # @param url [String] the service entry's `endpoint`; paths are
          #   appended to it, keeping any version prefix.
          # @param proxy [String, Hash, URI, nil] as for Http.
          def initialize(url:, headers: {}, proxy: nil)
            @base = url.to_s.chomp("/")
            @connection = Faraday.new(headers: Client.with_user_agent(headers), proxy: proxy)
          end

          # Returns the response body as a string-keyed Hash, like Http.
          def call_tool(name:, arguments:, meta: nil)
            verb, path, wrapper = ROUTES.fetch(name) do
              raise UnsupportedWireShapeError, "#{name} has no REST operation in UCP 2026-08-25"
            end
            idempotency_key = arguments[:idempotency_key] || arguments["idempotency_key"]
            wire = wire_arguments(name, arguments)
            headers = request_headers(meta, idempotency_key)
            body = wrapper && JSON.generate(wire.fetch(wrapper))
            response = @connection.run_request(verb.downcase.to_sym, url_for(path, wire["id"]), body, headers)
            handle(response, name)
          end

          private

          def url_for(path, id)
            @base + path.sub("{id}") { URI.encode_www_form_component(id.to_s) }
          end

          def request_headers(meta, idempotency_key)
            profile = meta && (meta[:agent_profile] || meta["agent_profile"])
            unless profile
              raise MissingAgentProfileError,
                    "meta: { agent_profile: <url> } is required for REST calls — real UCP servers fetch " \
                    "and verify this URL to identify the calling agent"
            end

            headers = { "UCP-Agent" => %(profile="#{profile}"),
                        "Content-Type" => "application/json", "Accept" => "application/json" }
            headers["Idempotency-Key"] = idempotency_key if idempotency_key
            headers
          end

          def handle(response, name)
            payload = parse(response.body)
            return payload if response.success? && payload

            error = ServerError.new("HTTP #{response.status}: #{detail(payload, response.body)}", payload: payload)
            raise permission_error(error) if name == "complete_checkout" &&
                                             (response.status == 403 || permission_refusal?(error.message))

            raise error
          end

          def detail(payload, body)
            contents = Array(payload && payload["messages"]).filter_map { |m| m["content"] if m.is_a?(Hash) }
            contents.empty? ? body : contents.join("; ")
          end

          def parse(body)
            parsed = JSON.parse(body.to_s)
            parsed.is_a?(Hash) ? parsed : nil
          rescue JSON::ParserError
            nil
          end
        end
      end
    end
  end
end
