require_relative "../errors"
require_relative "http/complete_checkout_wire_shape"

module Portage
  module Ucp
    module Client
      module Transports
        # Connects to a UCP/MCP server over Streamable HTTP via the official
        # `mcp` gem's client half (MCP::Client + MCP::Client::HTTP). Performs
        # the `initialize` handshake eagerly so a caller's first real call
        # doesn't pay for it.
        #
        # Session's public API (query:/limit:, cart_id:/checkout_id:/
        # order_id:, line_items: [{product_id:, quantity:}], ...) stays flat
        # — it's shared with Loopback, which hands arguments straight to this
        # gem's own Dispatcher/adapters, and those speak that flat shape by
        # design (see portage-ucp/lib/portage/ucp/mcp/server.rb). Real UCP
        # servers don't: confirmed live against Shopify's 2026-08-25 rollout,
        # every tool nests its arguments under a capability key
        # (catalog:/cart:/checkout:) and requires a `meta.ucp-agent.profile`
        # URL the server itself fetches to verify the caller's identity. This
        # transport is the one place that reshapes Session's flat arguments
        # into that real wire format before the request goes out — Loopback
        # and Stdio are untouched.
        class Http
          include CompleteCheckoutWireShape

          # Actions whose one identifying argument becomes a top-level `id`.
          ID_ARG = {
            "get_cart" => :cart_id, "cancel_cart" => :cart_id,
            "get_checkout" => :checkout_id, "cancel_checkout" => :checkout_id,
            "get_order" => :order_id
          }.freeze

          CATALOG_ACTIONS = %w[get_product lookup_catalog search_catalog].freeze
          CART_ACTIONS = %w[create_cart update_cart].freeze
          CHECKOUT_ACTIONS = %w[create_checkout update_checkout].freeze

          def initialize(url:, headers: {})
            @client = ::MCP::Client.new(transport: ::MCP::Client::HTTP.new(url: url, headers: headers))
            @client.connect
          end

          # `meta` here is a *property of the tool's own `arguments` object*
          # (confirmed live against Shopify's schema — every tool's
          # input_schema lists "meta" as a top-level sibling of
          # "catalog"/"cart"/"checkout"), not the MCP protocol's `_meta`
          # envelope field. `MCP::Client#call_tool`'s own `meta:` kwarg sends
          # the latter, so it's unused here — the caller-supplied meta gets
          # folded into `arguments["meta"]` instead.
          def call_tool(name:, arguments:, meta: nil)
            idempotency_key = arguments[:idempotency_key] || arguments["idempotency_key"]
            wire = wire_arguments(name, arguments)
            wire["meta"] = wire_meta(meta, idempotency_key)
            response = @client.call_tool(name: name, arguments: wire)
            ToolResult.extract(response, symbol_keys: false)
          rescue ServerError, MCP::Client::RequestHandlerError => e
            raise permission_error(e) if name == "complete_checkout" && permission_refusal?(e.message)

            raise
          end

          private

          # `idempotency_key` arrives via `arguments` — Session#call folds it
          # in there for every mutating action — not via `meta`, so it has to
          # be threaded through here rather than read off `meta` directly.
          def wire_meta(meta, idempotency_key)
            profile = meta && (meta[:agent_profile] || meta["agent_profile"])
            unless profile
              raise MissingAgentProfileError,
                    "meta: { agent_profile: <url> } is required for HTTP calls — real UCP servers fetch " \
                    "and verify this URL to identify the calling agent"
            end

            wire = { "ucp-agent" => { "profile" => profile } }
            wire["idempotency-key"] = idempotency_key if idempotency_key
            wire
          end

          def wire_arguments(name, arguments)
            idempotency_key = arguments[:idempotency_key] || arguments["idempotency_key"]
            arguments = arguments.dup
            arguments.delete(:idempotency_key)

            return complete_checkout_body(arguments, idempotency_key) if name == "complete_checkout"
            return { "id" => arguments.fetch(ID_ARG[name]) } if ID_ARG.key?(name)
            return catalog_body(name, arguments) if CATALOG_ACTIONS.include?(name)
            return wrap_line_items("cart", arguments, id_key: :cart_id) if CART_ACTIONS.include?(name)
            return wrap_line_items("checkout", arguments, id_key: :checkout_id) if CHECKOUT_ACTIONS.include?(name)

            arguments
          end

          def catalog_body(name, arguments)
            body = case name
                   when "get_product" then { "id" => arguments.fetch(:product_id) }
                   when "lookup_catalog" then { "ids" => arguments.fetch(:product_ids) }
                   when "search_catalog" then search_catalog_body(arguments)
                   end
            { "catalog" => with_context(body, arguments) }
          end

          # `context` carries the buyer's locale/currency/region hints the UCP
          # `context` object is specified for. It looks optional and isn't:
          # Shopify resolves which market (and therefore which publication and
          # inventory) a call is scoped to from it, and a cart built without it
          # comes back with `line_items: []`, zeroed totals, and a
          # `merchandise_out_of_stock` warning naming a product `search_catalog`
          # had just reported as `availability.available == true` on the same
          # store. Confirmed live 2026-09-22: identical `create_cart`, context
          # added, returns the line item at its real price. So an omitted
          # context doesn't degrade results, it silently empties the cart.
          def with_context(body, arguments)
            context = arguments[:context] || arguments["context"]
            return body if context.nil? || context.empty?

            body.merge("context" => stringify(context))
          end

          def stringify(context)
            context.to_h { |key, value| [key.to_s, value] }
          end

          def search_catalog_body(arguments)
            { "query" => arguments[:query], "pagination" => { "limit" => arguments[:limit] }.compact }.compact
          end

          # `cart_id` on a checkout body is the cart→checkout conversion the
          # spec's `checkout.cart_id` describes ("the business uses cart
          # contents and ignores overlapping fields"). Its schema says
          # `cart_id` alone is enough; the live server disagrees and rejects
          # that with `Invalid arguments: object at '/checkout' is missing
          # required properties: line_items` (confirmed live 2026-09-22), so
          # the line items go out alongside it rather than instead of it.
          def wrap_line_items(wrapper, arguments, id_key:)
            body = { "line_items" => Array(arguments[:line_items]).map { |li| wire_line_item(li) } }
            body["cart_id"] = arguments[:cart_id] if wrapper == "checkout" && arguments[:cart_id]
            body = with_context(body, arguments)
            { wrapper => body }.tap { |h| h["id"] = arguments[id_key] if arguments[id_key] }
          end

          def wire_line_item(line_item)
            { "item" => { "id" => line_item[:product_id] || line_item["product_id"] },
              "quantity" => line_item[:quantity] || line_item["quantity"] }
          end
        end
      end
    end
  end
end
