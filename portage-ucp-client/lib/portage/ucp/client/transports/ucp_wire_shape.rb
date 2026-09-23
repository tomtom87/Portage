require_relative "http/complete_checkout_wire_shape"

module Portage
  module Ucp
    module Client
      module Transports
        # Session's flat arguments reshaped into the real UCP wire format —
        # every tool nests its arguments under a capability key
        # (catalog:/cart:/checkout:), confirmed live against Shopify's
        # 2026-08-25 rollout (see Transports::Http). Split out of Http so any
        # transport that reaches a UCP-shaped tool surface (Streamable HTTP
        # today, a page's WebMCP tools in portage-ucp-webmcp) builds the same
        # body from the same code rather than a second copy drifting from it.
        # Private instance methods of the including transport, as before.
        module UcpWireShape
          include Http::CompleteCheckoutWireShape

          # Actions whose one identifying argument becomes a top-level `id`.
          ID_ARG = {
            "get_cart" => :cart_id, "cancel_cart" => :cart_id,
            "get_checkout" => :checkout_id, "cancel_checkout" => :checkout_id,
            "get_order" => :order_id
          }.freeze

          CATALOG_ACTIONS = %w[get_product lookup_catalog search_catalog].freeze
          CART_ACTIONS = %w[create_cart update_cart].freeze
          CHECKOUT_ACTIONS = %w[create_checkout update_checkout].freeze

          private

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
          # added, returns the line item at its real price.
          #
          # A sweep of nine third-party Shopify stores the same day found the
          # empty cart is only the loudest of three outcomes for an omitted
          # context. Three stores built a correct cart without one; one
          # emptied it; five priced it in the market of the *caller's IP*
          # (a run from Bangkok got THB totals from stores whose shoppers had
          # asked for nothing of the sort). So an omitted context doesn't
          # merely degrade results — it produces a valid-shaped cart at the
          # wrong currency, with nothing on the response saying so, which is
          # the harder failure to notice of the two.
          #
          # Sending one is necessary, not sufficient: the cart is scoped to
          # the market the context names, so a product the store doesn't
          # publish into that market drops out with the same
          # `merchandise_out_of_stock` message (mejuri.com, `US`/`USD` and
          # `GB`/`GBP` empty, `CA`/`CAD` fine). That store's `search_catalog`
          # ignored the context entirely and quoted CAD at
          # `available: true` for every market asked, so the search result
          # gives a caller no warning. Nothing to fix here — it's the store's
          # market config — but callers shouldn't read this code as a
          # guarantee that a context makes carts work.
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
