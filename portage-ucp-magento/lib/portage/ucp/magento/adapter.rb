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
        # The guest-cart API takes no idempotency key natively, so §9a dedup
        # comes from Support::Idempotency's in-process table.
        include Portage::Ucp::Support::Idempotency
        # A Magento guest cart has no native status field, and an Order's own
        # `quote_id` is the cart's internal integer id rather than the masked
        # guest-cart id this gem uses (see Mapper.order) — both are tracked
        # adapter-side via Support::CheckoutState.
        include Portage::Ucp::Support::CheckoutState
        # The admin-token API answers a missing product or order with a 404
        # rather than an empty body, which UCP's reads report as nil.
        include Portage::Ucp::Support::NotFound

        def initialize(client:, currency:, site_url: nil, payment_method: nil, payment_data_key: "cc_token",
                       default_address: nil)
          super()
          @client = client
          @currency = currency
          @site_url = site_url&.chomp("/")
          @payment_method = payment_method
          @payment_data_key = payment_data_key
          @default_address = default_address
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
          nil_on_not_found do
            node = @client.admin_get("/products/#{URI.encode_www_form_component(product_id)}")
            node["sku"] ? Mapper.product(with_children(node), currency: @currency, site_url: @site_url) : nil
          end
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
            record_checkout_status(cart_id, "incomplete")
            items, currency = cart_snapshot(cart_id)
            Mapper.checkout(items, id: cart_id, currency: currency, status: "incomplete")
          end
        end

        def get_checkout(checkout_id:)
          items, currency = cart_snapshot(checkout_id)
          Mapper.checkout(items, id: checkout_id, currency: currency,
                                 status: checkout_status(checkout_id))
        end

        # Full replacement, same rationale as #update_cart.
        def update_checkout(checkout_id:, line_items:, idempotency_key:)
          dedup(idempotency_key) do
            replace_items(checkout_id, line_items)
            items, currency = cart_snapshot(checkout_id)
            record_checkout_status(checkout_id, "incomplete")
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
            record_checkout_status(checkout_id, "canceled")
            items, currency = cart_snapshot(checkout_id)
            Mapper.checkout(items, id: checkout_id, currency: currency, status: "canceled")
          end
        end

        def get_order(order_id:)
          nil_on_not_found do
            node = @client.admin_get("/orders/#{order_id}")
            next nil unless node["entity_id"]

            Mapper.order(node, checkout_id: checkout_id_for(order_id))
          end
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
          submit_shipping_information(checkout_id)
          order_id = submit_payment_information(checkout_id, payment_token)
          record_checkout_status(checkout_id, "completed")
          record_order_checkout(order_id, checkout_id)
          Mapper.checkout(items, id: checkout_id, currency: currency, status: "completed",
                                 order: order_confirmation(order_id))
        end

        def submit_shipping_information(checkout_id)
          @client.guest_post("/guest-carts/#{checkout_id}/shipping-information",
                             { addressInformation: { shipping_address: @default_address,
                                                     billing_address: @default_address,
                                                     shipping_carrier_code: "flatrate",
                                                     shipping_method_code: "flatrate" } })
        end

        def submit_payment_information(checkout_id, payment_token)
          @client.guest_post("/guest-carts/#{checkout_id}/payment-information",
                             { email: @default_address[:email] || "guest@example.com",
                               paymentMethod: { method: @payment_method,
                                                additional_data: { @payment_data_key => payment_token } },
                               billingAddress: @default_address })
        end

        # Same blank permalink_url posture as Mapper.order — Magento has no
        # public order-status link to hand back here either.
        def order_confirmation(order_id)
          Portage::Ucp::OrderConfirmation.new(id: order_id.to_s, permalink_url: "")
        end
      end
    end
  end
end
