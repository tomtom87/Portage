require "uri"

module Portage
  module Ucp
    module Magento
      # Generic Portage::Ucp::Adapter over a Magento/Adobe Commerce site's
      # REST v1 API — no merchant-specific business logic, same posture as
      # Portage::Ucp::Shopify::Adapter and Portage::Ucp::WooCommerce::Adapter.
      #
      # Deliberately doesn't override `link_identity`: Magento customer
      # account login is a separate concern from the admin token and
      # anonymous guest-cart flow this gem uses, so this generic adapter
      # leaves it unimplemented — Capability#advertised_for? simply won't
      # advertise dev.ucp.shopping.identity for this adapter, not a 500.
      #
      # Catalog and Order are read through the admin-token API. Cart and
      # Checkout are read/written through the anonymous guest-cart API — a
      # Magento guest cart *is* the checkout (there's no separate Checkout
      # resource), same as Shopify's Cart-as-Checkout.
      #
      # IMPORTANT CAVEATS:
      #
      # - #complete_checkout needs a billing/shipping address to call
      #   Magento's real guest-checkout flow (`shipping-information` then
      #   `payment-information`) — UCP's `complete_checkout(checkout_id:,
      #   payment_token:, idempotency_key:)` carries no address at all. This
      #   adapter works around that with a single `default_address:`
      #   configured at initialization (every order ships/bills to the
      #   same address) rather than guessing a UCP address extension that
      #   doesn't exist yet — fine for a single-fulfillment-address
      #   integration, wrong for anything else.
      # - `payment_data` shape is gateway-specific (configured via
      #   `payment_method:`/`payment_data_key:`) and hasn't been confirmed
      #   against a live site with a real gateway installed — same posture
      #   as Portage::Ucp::WooCommerce::Adapter's own payment step.
      class Adapter < Portage::Ucp::Adapter
        def initialize(client:, currency:, site_url: nil, payment_method: nil, payment_data_key: "cc_token",
                       default_address: nil)
          super()
          @client = client
          @currency = currency
          @site_url = site_url&.chomp("/")
          @payment_method = payment_method
          @payment_data_key = payment_data_key
          @default_address = default_address
          # §9a: mutating Adapter methods must dedup by idempotency_key so an
          # agent's retry on a dropped connection can't double-charge. The
          # guest-cart API takes no idempotency key natively, so this
          # adapter keeps its own in-process dedup table, same as
          # Portage::Ucp::Shopify::Adapter.
          @idempotency_results = {}
          # A Magento guest cart has no native status field, so status is
          # tracked here across the create/update/complete/cancel
          # lifecycle, keyed by the masked cart id.
          @checkout_status = {}
          # See Mapper.order's comment: an Order's own `quote_id` is the
          # cart's internal integer id, not the masked guest-cart id this
          # gem uses everywhere, and Magento doesn't expose that mapping via
          # the API — so the Adapter records it itself at #complete_checkout
          # time instead, same as Portage::Ucp::WooCommerce::Adapter.
          @order_checkout_ids = {}
        end

        def search_catalog(query:, limit:)
          params = { "searchCriteria[filterGroups][0][filters][0][field]" => "name",
                     "searchCriteria[filterGroups][0][filters][0][value]" => "%#{query}%",
                     "searchCriteria[filterGroups][0][filters][0][conditionType]" => "like",
                     "searchCriteria[pageSize]" => limit }
          data = @client.admin_get("/products?#{URI.encode_www_form(params)}")
          (data["items"] || []).map { |node| Mapper.product(node, currency: @currency, site_url: @site_url) }
        end

        def get_product(product_id:)
          node = @client.admin_get("/products/#{URI.encode_www_form_component(product_id)}")
          node["sku"] ? Mapper.product(with_children(node), currency: @currency, site_url: @site_url) : nil
        rescue Portage::Ucp::Magento::ApiError => e
          raise unless e.status == 404

          nil
        end

        def get_cart(cart_id:)
          items, currency = cart_snapshot(cart_id)
          Mapper.cart(items, id: cart_id, currency: currency)
        end

        def create_cart(line_items:, idempotency_key:)
          dedup(idempotency_key) do
            cart_id = @client.guest_post("/guest-carts")
            add_items(cart_id, line_items)
            items, currency = cart_snapshot(cart_id)
            Mapper.cart(items, id: cart_id, currency: currency)
          end
        end

        # Full replacement, same rationale as Portage::Ucp::Shopify::Adapter
        # #update_cart: Magento's guest-cart items API has no atomic
        # "replace all lines" either, so this removes every current line
        # then adds the desired ones back.
        def update_cart(cart_id:, line_items:, idempotency_key:)
          dedup(idempotency_key) do
            replace_items(cart_id, line_items)
            items, currency = cart_snapshot(cart_id)
            Mapper.cart(items, id: cart_id, currency: currency)
          end
        end

        # A guest cart is tied to its quote, not a deletable resource with
        # its own lifecycle — there's no cancellation call, so this clears
        # every line and returns the now-empty cart, the closest real
        # equivalent (same posture as Portage::Ucp::WooCommerce::Adapter).
        def cancel_cart(cart_id:, idempotency_key:)
          dedup(idempotency_key) do
            replace_items(cart_id, [])
            items, currency = cart_snapshot(cart_id)
            Mapper.cart(items, id: cart_id, currency: currency)
          end
        end

        def create_checkout(line_items:, idempotency_key:)
          dedup(idempotency_key) do
            cart_id = @client.guest_post("/guest-carts")
            add_items(cart_id, line_items)
            @checkout_status[cart_id] = "incomplete"
            items, currency = cart_snapshot(cart_id)
            Mapper.checkout(items, id: cart_id, currency: currency, status: "incomplete")
          end
        end

        def get_checkout(checkout_id:)
          items, currency = cart_snapshot(checkout_id)
          Mapper.checkout(items, id: checkout_id, currency: currency,
                                 status: @checkout_status.fetch(checkout_id, "incomplete"))
        end

        # Full replacement, same rationale as #update_cart.
        def update_checkout(checkout_id:, line_items:, idempotency_key:)
          dedup(idempotency_key) do
            replace_items(checkout_id, line_items)
            items, currency = cart_snapshot(checkout_id)
            @checkout_status[checkout_id] = "incomplete"
            Mapper.checkout(items, id: checkout_id, currency: currency, status: "incomplete")
          end
        end

        def complete_checkout(checkout_id:, payment_token:, idempotency_key:)
          dedup(idempotency_key) { submit_checkout(checkout_id, payment_token) }
        end

        # Magento has no cancellation endpoint for an in-progress guest cart
        # either (see #cancel_cart) — this just marks the tracked status
        # canceled without touching the underlying cart contents.
        def cancel_checkout(checkout_id:, idempotency_key:)
          dedup(idempotency_key) do
            @checkout_status[checkout_id] = "canceled"
            items, currency = cart_snapshot(checkout_id)
            Mapper.checkout(items, id: checkout_id, currency: currency, status: "canceled")
          end
        end

        def get_order(order_id:)
          node = @client.admin_get("/orders/#{order_id}")
          return nil unless node["entity_id"]

          Mapper.order(node, checkout_id: @order_checkout_ids.fetch(order_id.to_s, ""))
        rescue Portage::Ucp::Magento::ApiError => e
          raise unless e.status == 404

          nil
        end

        private

        # Merges the guest-cart `items` resource (sku/name/qty/price) with
        # the `totals` resource (row_total/tax_amount/quote_currency_code)
        # by `item_id` — see Mapper.cart's comment on why Magento needs this
        # two-call merge where Shopify/Wix/WooCommerce each have one
        # response that already carries everything.
        def cart_snapshot(cart_id)
          items = @client.guest_get("/guest-carts/#{cart_id}/items")
          totals_data = @client.guest_get("/guest-carts/#{cart_id}/totals")
          totals_by_id = (totals_data["items"] || []).to_h { |t| [t["item_id"], t] }
          merged = items.map { |i| i.merge(totals_by_id.fetch(i["item_id"], {})) }
          [merged, totals_data["quote_currency_code"] || @currency]
        end

        # A variable product's own resource only lists child skus under
        # `extension_attributes.configurable_product_links` — fetching the
        # full child product objects is a second call, only made for
        # #get_product's single-product path, not #search_catalog's list
        # (an N+1 fetch per search result would be too expensive).
        def with_children(node)
          return node unless node["type_id"] == "configurable"

          children = @client.admin_get("/configurable-products/#{URI.encode_www_form_component(node['sku'])}/children")
          node.merge("children_detail" => children)
        end

        def add_items(cart_id, line_items)
          line_items.each do |li|
            @client.guest_post("/guest-carts/#{cart_id}/items",
                               { cartItem: { sku: li[:product_id], qty: li[:quantity], quote_id: cart_id } })
          end
        end

        def replace_items(cart_id, line_items)
          current = @client.guest_get("/guest-carts/#{cart_id}/items")
          current.each { |item| @client.guest_delete("/guest-carts/#{cart_id}/items/#{item['item_id']}") }
          add_items(cart_id, line_items)
        end

        # See the class-level CAVEATS: `default_address` stands in for
        # UCP's missing per-checkout address, and `payment_data` uses a
        # single configurable key rather than a confirmed gateway-specific
        # shape.
        def verify_checkout_configured!
          raise Portage::Ucp::Magento::Error, "no payment_method configured on this Adapter" unless @payment_method
          raise Portage::Ucp::Magento::Error, "no default_address configured on this Adapter" unless @default_address
        end

        def submit_checkout(checkout_id, payment_token)
          verify_checkout_configured!
          items, currency = cart_snapshot(checkout_id)
          @client.guest_post("/guest-carts/#{checkout_id}/shipping-information",
                             { addressInformation: { shipping_address: @default_address,
                                                     billing_address: @default_address,
                                                     shipping_carrier_code: "flatrate",
                                                     shipping_method_code: "flatrate" } })
          order_id = @client.guest_post("/guest-carts/#{checkout_id}/payment-information",
                                        { email: @default_address[:email] || "guest@example.com",
                                          paymentMethod: { method: @payment_method,
                                                           additional_data: { @payment_data_key => payment_token } },
                                          billingAddress: @default_address })
          @checkout_status[checkout_id] = "completed"
          @order_checkout_ids[order_id.to_s] = checkout_id
          Mapper.checkout(items, id: checkout_id, currency: currency, status: "completed")
        end

        def dedup(idempotency_key)
          return @idempotency_results[idempotency_key] if @idempotency_results.key?(idempotency_key)

          @idempotency_results[idempotency_key] = yield
        end
      end
    end
  end
end
