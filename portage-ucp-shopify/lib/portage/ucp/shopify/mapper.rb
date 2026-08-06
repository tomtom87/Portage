require "bigdecimal"

module Portage
  module Ucp
    module Shopify
      # Converts Shopify GraphQL response nodes into the protocol-layer value
      # objects from Portage::Ucp::ValueObjects (Product/Cart/LineItem/Checkout/Order/
      # Money) — nothing Shopify-shaped is allowed to leak past this file.
      #
      # UCP's LineItem#item.id is Shopify's variant GID, not the parent
      # product's GID: Shopify carts hold variants (a specific size/color), and
      # a product with one variant just uses that variant's id.
      module Mapper
        module_function

        def money(price)
          Portage::Ucp::Money.new(amount_minor: (BigDecimal(price["amount"]) * 100).to_i,
                                  currency: price["currencyCode"])
        end

        def minor_units(price)
          (BigDecimal(price["amount"]) * 100).to_i
        end

        def product(node)
          Portage::Ucp::Product.new(
            id: node["id"],
            title: node["title"],
            description: node["description"],
            price: money(node.dig("priceRange", "minVariantPrice")),
            available: node["availableForSale"],
            variants: node.dig("variants", "nodes").map { |v| variant(v) },
            url: node["onlineStoreUrl"]
          )
        end

        def variant(node)
          { id: node["id"], title: node["title"], available: node["availableForSale"], price: money(node["price"]) }
        end

        def cart(node)
          Portage::Ucp::Cart.new(
            id: node["id"],
            line_items: node.dig("lines", "nodes").map { |n| cart_line_item(n) },
            currency: node.dig("cost", "subtotalAmount", "currencyCode"),
            totals: totals(node)
          )
        end

        def cart_line_item(node)
          merchandise = node["merchandise"]
          line_total = minor_units(node.dig("cost", "totalAmount"))
          Portage::Ucp::LineItem.new(
            id: node["id"],
            item: Portage::Ucp::Item.new(id: merchandise["id"], title: merchandise.dig("product", "title"),
                                         price: minor_units(merchandise["price"])),
            quantity: node["quantity"],
            totals: [Portage::Ucp::Total.new(type: "subtotal", amount: line_total),
                     Portage::Ucp::Total.new(type: "total", amount: line_total)]
          )
        end

        # `status` isn't a Shopify Cart field — Cart/Checkout is one object in
        # Shopify's model, so the adapter tracks status itself across the
        # create/update/complete/cancel lifecycle and passes it in here.
        def checkout(node, status:, order: nil)
          Portage::Ucp::Checkout.new(
            id: node["id"],
            status: status,
            line_items: node.dig("lines", "nodes").map { |n| cart_line_item(n) },
            currency: node.dig("cost", "subtotalAmount", "currencyCode"),
            totals: totals(node),
            links: [],
            order: order
          )
        end

        # `checkout_id` isn't a Shopify Order field — nothing on Order links
        # back to its originating cart, so the adapter resolves it itself (via
        # a cart_token order search at completion time, see
        # Portage::Ucp::Shopify::Adapter#link_cart_to_order) and passes it in here,
        # the same way #checkout's `status:` is caller-supplied.
        def order(node, checkout_id: "")
          subtotal_amount = minor_units(node.dig("currentSubtotalPriceSet", "shopMoney"))
          total_amount = minor_units(node.dig("currentTotalPriceSet", "shopMoney"))
          Portage::Ucp::Order.new(
            id: node["id"],
            checkout_id: checkout_id,
            permalink_url: node["statusPageUrl"],
            line_items: node.dig("lineItems", "nodes").map { |n| order_line_item(n) },
            fulfillment: fulfillment(node),
            currency: node.dig("currentTotalPriceSet", "shopMoney", "currencyCode"),
            totals: [Portage::Ucp::Total.new(type: "subtotal", amount: subtotal_amount),
                     Portage::Ucp::Total.new(type: "total", amount: total_amount)]
          )
        end

        def order_line_item(node)
          variant_node = node["variant"]
          line_total = minor_units(node.dig("discountedTotalSet", "shopMoney"))
          total = node["currentQuantity"]
          fulfilled = total - node["unfulfilledQuantity"]
          Portage::Ucp::OrderLineItem.new(
            id: node["id"],
            item: Portage::Ucp::Item.new(id: variant_node && variant_node["id"],
                                         title: variant_node && variant_node["title"],
                                         price: variant_node && minor_units(variant_node["price"])),
            quantity: { original: node["quantity"], total: total, fulfilled: fulfilled },
            totals: [Portage::Ucp::Total.new(type: "subtotal", amount: line_total),
                     Portage::Ucp::Total.new(type: "total", amount: line_total)],
            status: order_line_item_status(total, fulfilled)
          )
        end

        def order_line_item_status(total, fulfilled)
          return "removed" if total.zero?
          return "fulfilled" if fulfilled == total
          return "partial" if fulfilled.positive?

          "processing"
        end

        # DeliveryMethodType (Shopify) -> method_type enum (UCP). Unmapped
        # values (new enum members Shopify adds later) fall back to "shipping"
        # rather than raising, so a schema-valid guess beats a hard failure.
        DELIVERY_METHOD_TYPES = {
          "SHIPPING" => "shipping", "LOCAL" => "shipping", "PICKUP_POINT" => "shipping",
          "PICK_UP" => "pickup", "RETAIL" => "pickup",
          "NONE" => "digital"
        }.freeze

        # FulfillmentDisplayStatus (Shopify) -> fulfillment_event `type` (UCP).
        # Unmapped values fall back to "processing", same rationale as above.
        FULFILLMENT_EVENT_TYPES = {
          "ATTEMPTED_DELIVERY" => "failed_attempt", "CANCELED" => "canceled", "CONFIRMED" => "processing",
          "DELAYED" => "in_transit", "DELIVERED" => "delivered", "FAILURE" => "failed_attempt",
          "FULFILLED" => "shipped", "CARRIER_PICKED_UP" => "shipped", "IN_TRANSIT" => "in_transit",
          "LABEL_PRINTED" => "processing", "LABEL_PURCHASED" => "processing", "LABEL_VOIDED" => "canceled",
          "MARKED_AS_FULFILLED" => "shipped", "NOT_DELIVERED" => "undeliverable", "OUT_FOR_DELIVERY" => "in_transit",
          "READY_FOR_PICKUP" => "processing", "PICKED_UP" => "delivered", "SUBMITTED" => "processing"
        }.freeze

        # Builds the buyer-facing Fulfillment (schemas/shopping/order.json's
        # `expectations`/`events`) from Shopify's fulfillmentOrders (what's
        # expected to ship, and to where) and fulfillments (what actually
        # shipped, with tracking).
        def fulfillment(node)
          Portage::Ucp::Fulfillment.new(
            expectations: (node.dig("fulfillmentOrders", "nodes") || []).map { |n| expectation(n) },
            events: (node["fulfillments"] || []).map { |n| fulfillment_event(n) }
          )
        end

        def expectation(node)
          Portage::Ucp::Expectation.new(
            id: node["id"],
            line_items: (node.dig("lineItems", "nodes") || []).map { |n| order_line_ref(n, n["totalQuantity"]) },
            method_type: DELIVERY_METHOD_TYPES.fetch(node.dig("deliveryMethod", "methodType"), "shipping"),
            destination: postal_address(node["destination"]),
            fulfillable_on: node["fulfillAt"]
          )
        end

        def postal_address(node)
          return {} unless node

          {
            "street_address" => node["address1"], "extended_address" => node["address2"],
            "address_locality" => node["city"], "address_region" => node["province"],
            "address_country" => node["countryCode"], "postal_code" => node["zip"],
            "first_name" => node["firstName"], "last_name" => node["lastName"], "phone_number" => node["phone"]
          }.compact
        end

        def fulfillment_event(node)
          tracking = node.dig("trackingInfo", 0) || {}
          line_items = (node.dig("fulfillmentLineItems", "nodes") || [])
                       .map { |n| order_line_ref(n, n["quantity"]) }
                       .select { |n| n["quantity"]&.positive? }
          Portage::Ucp::FulfillmentEvent.new(
            id: node["id"], occurred_at: node["createdAt"],
            type: FULFILLMENT_EVENT_TYPES.fetch(node["displayStatus"], "processing"),
            line_items: line_items,
            tracking_number: tracking["number"], tracking_url: tracking["url"], carrier: tracking["company"]
          )
        end

        def order_line_ref(node, quantity)
          { "id" => node.dig("lineItem", "id"), "quantity" => quantity }
        end

        # Builds the top-level totals array (exactly one subtotal + one total,
        # plus an optional tax entry) from Shopify's cost breakdown.
        def totals(node)
          cost = node["cost"]
          entries = [Portage::Ucp::Total.new(type: "subtotal", amount: minor_units(cost["subtotalAmount"]))]
          tax = minor_units(cost["totalTaxAmount"])
          entries << Portage::Ucp::Total.new(type: "tax", amount: tax) if tax.positive?
          entries << Portage::Ucp::Total.new(type: "total", amount: minor_units(cost["totalAmount"]))
          entries
        end
      end
    end
  end
end
