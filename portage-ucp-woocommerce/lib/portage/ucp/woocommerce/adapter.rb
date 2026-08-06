require "uri"

module Portage
  module Ucp
    module WooCommerce
      # Generic Portage::Ucp::Adapter over a WooCommerce site's Admin REST
      # API v3 (catalog, order) and Store API v1 (cart, checkout) — no
      # merchant-specific business logic, same posture as
      # Portage::Ucp::Shopify::Adapter.
      #
      # Deliberately doesn't override `link_identity`: WooCommerce/WordPress
      # user auth is a separate concern from the store-owner Admin keys and
      # anonymous Store API session this gem uses, so this generic adapter
      # leaves it unimplemented — Capability#advertised_for? simply won't
      # advertise dev.ucp.shopping.identity for this adapter, not a 500.
      #
      # Catalog and Order are read through the Admin API (the Store API has
      # no product search and can't look up an arbitrary past order without
      # a customer session). Cart and Checkout are read/written through the
      # Store API — Admin's REST v3 has no "Cart" resource at all, only
      # Orders, and an Order only exists once checkout completes.
      #
      # IMPORTANT CAVEAT: #complete_checkout calls the Store API's
      # `/checkout` endpoint with `payment_method` (configured at
      # initialization, since it must match an installed, enabled WC
      # payment gateway id) and `payment_data` built from `payment_token`.
      # The exact `payment_data` key(s) a given gateway expects are gateway-
      # specific (e.g. Stripe's block-based gateway reads a different key
      # than PayPal's) and this hasn't been confirmed against a live site
      # with a real gateway installed — same "needs confirming against a
      # live store" posture as Portage::Ucp::Shopify::Adapter's own payment
      # step.
      class Adapter < Portage::Ucp::Adapter
        # The Store API takes no idempotency key natively, so §9a dedup comes
        # from Support::Idempotency's in-process table.
        include Portage::Ucp::Support::Idempotency
        # Store API cart and checkout share one underlying session (keyed by
        # Cart-Token) with no status of its own, and WC orders don't link
        # back to the Cart-Token that produced them (see Mapper.order) —
        # both are tracked adapter-side via Support::CheckoutState.
        include Portage::Ucp::Support::CheckoutState
        # The Admin API answers a missing product or order with a 404 rather
        # than an empty body, which UCP's reads report as nil.
        include Portage::Ucp::Support::NotFound

        def initialize(client:, site_url:, currency:, payment_method: nil, payment_data_key: "token")
          super()
          @client = client
          @site_url = site_url.chomp("/")
          @currency = currency
          @payment_method = payment_method
          @payment_data_key = payment_data_key
        end

        def search_catalog(query:, limit:)
          data = @client.admin_get("/products?search=#{URI.encode_www_form_component(query)}&per_page=#{limit}")
          data.map { |node| Mapper.product(node, currency: @currency) }
        end

        def get_product(product_id:)
          nil_on_not_found do
            node = @client.admin_get("/products/#{product_id}")
            node["id"] ? Mapper.product(with_variations(node), currency: @currency) : nil
          end
        end

        def get_cart(cart_id:)
          Mapper.cart(fetch_cart_node, id: cart_id)
        end

        def create_cart(line_items:, idempotency_key:)
          dedup(idempotency_key) { Mapper.cart(replace_cart_lines(line_items), id: @client.cart_token) }
        end

        # Full replacement, same rationale as Portage::Ucp::Shopify::Adapter
        # #update_cart: the Store API has no atomic "replace all lines"
        # either, so this removes every current line then adds the desired
        # ones back.
        def update_cart(cart_id:, line_items:, idempotency_key:)
          dedup(idempotency_key) { Mapper.cart(replace_cart_lines(line_items), id: cart_id) }
        end

        # The Store API's cart is tied to a session, not a deletable
        # resource with its own lifecycle — there's no cancellation call,
        # so this clears every line and returns the now-empty cart, the
        # closest real equivalent.
        def cancel_cart(cart_id:, idempotency_key:)
          dedup(idempotency_key) { Mapper.cart(replace_cart_lines([]), id: cart_id) }
        end

        def create_checkout(line_items:, idempotency_key:)
          dedup(idempotency_key) do
            node = replace_cart_lines(line_items)
            record_checkout_status(@client.cart_token, "incomplete")
            Mapper.checkout(node, id: @client.cart_token, status: "incomplete")
          end
        end

        def get_checkout(checkout_id:)
          Mapper.checkout(fetch_cart_node, id: checkout_id, status: checkout_status(checkout_id))
        end

        # Full replacement, same rationale as #update_cart.
        def update_checkout(checkout_id:, line_items:, idempotency_key:)
          dedup(idempotency_key) do
            node = replace_cart_lines(line_items)
            record_checkout_status(checkout_id, "incomplete")
            Mapper.checkout(node, id: checkout_id, status: "incomplete")
          end
        end

        def complete_checkout(checkout_id:, payment_token:, idempotency_key:)
          dedup(idempotency_key) { submit_checkout(checkout_id, payment_token) }
        end

        # The Store API has no cancellation endpoint for an in-progress
        # checkout either (see #cancel_cart) — this just marks the tracked
        # status canceled without touching the underlying cart contents.
        def cancel_checkout(checkout_id:, idempotency_key:)
          dedup(idempotency_key) do
            record_checkout_status(checkout_id, "canceled")
            Mapper.checkout(fetch_cart_node, id: checkout_id, status: "canceled")
          end
        end

        def get_order(order_id:)
          nil_on_not_found do
            node = @client.admin_get("/orders/#{order_id}")
            next nil unless node["id"]

            Mapper.order(node, site_url: @site_url, checkout_id: checkout_id_for(order_id))
          end
        end

        private

        def fetch_cart_node
          @client.store_get("/cart")
        end

        # A variable product's Admin resource only lists variation *ids*
        # (`variations: [123, 124]`) — fetching the full variation objects
        # (price, stock, attribute choices) is a second call, only made for
        # #get_product's single-product path, not #search_catalog's list
        # (an N+1 fetch per search result would be too expensive).
        def with_variations(node)
          return node unless node["type"] == "variable" && node["variations"]&.any?

          node.merge("variations_detail" => @client.admin_get("/products/#{node['id']}/variations?per_page=100"))
        end

        def cart_lines(line_items)
          line_items.map { |li| { id: li[:product_id].to_i, quantity: li[:quantity] } }
        end

        def replace_cart_lines(line_items)
          fetch_cart_node["items"].each { |item| @client.store_post("/cart/remove-item", { key: item["key"] }) }
          cart_lines(line_items).each { |line| @client.store_post("/cart/add-item", line) }
          fetch_cart_node
        end

        # See the class-level CAVEAT: `payment_data` uses a single
        # configurable key (`payment_data_key:`, default "token") rather
        # than a confirmed gateway-specific shape.
        def submit_checkout(checkout_id, payment_token)
          raise Portage::Ucp::WooCommerce::Error, "no payment_method configured on this Adapter" unless @payment_method

          data = @client.store_post("/checkout", {
                                      payment_method: @payment_method,
                                      payment_data: [{ key: @payment_data_key, value: payment_token }]
                                    })
          record_checkout_status(checkout_id, "completed")
          order = build_order_confirmation(data, checkout_id)
          Mapper.checkout(data, id: checkout_id, status: "completed", order: order)
        end

        # Same order-received URL pattern as Mapper.order's `permalink_url` —
        # the Store API's checkout response hands back order_id/order_key
        # directly, so there's no need for a second Admin fetch just to build
        # this link.
        def build_order_confirmation(data, checkout_id)
          return unless data["order_id"]

          record_order_checkout(data["order_id"], checkout_id)
          Portage::Ucp::OrderConfirmation.new(
            id: data["order_id"].to_s,
            permalink_url: "#{@site_url}/checkout/order-received/#{data['order_id']}/?key=#{data['order_key']}"
          )
        end
      end
    end
  end
end
