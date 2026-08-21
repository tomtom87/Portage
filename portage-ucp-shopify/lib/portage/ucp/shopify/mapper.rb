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

        # Both take a Shopify MoneyV2 node ({amount:, currencyCode:}) rather
        # than a bare amount — the arithmetic itself is Support::Amounts'.
        def money(price)
          Portage::Ucp::Support::Amounts.money(price["amount"], price["currencyCode"])
        end

        def minor_units(price)
          Portage::Ucp::Support::Amounts.decimal_to_minor(price["amount"])
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
            totals: totals(node),
            discounts: discounts(node)
          )
        end

        # dev.ucp.shopping.discount — `codes` echoes every code Shopify has on
        # record for the cart (applicable or not); `applied` only lists
        # allocations that actually reduced the price, since that's all
        # `discountAllocations` ever returns. Allocation-level breakdown
        # (applied_discount's `allocations` field) isn't sourced here —
        # per-line attribution needs a separate line-level query this adapter
        # doesn't make yet.
        def discounts(node)
          codes = (node["discountCodes"] || []).map { |c| c["code"] }
          applied = (node["discountAllocations"] || []).map { |a| applied_discount(a) }
          Portage::Ucp::Discounts.new(codes: codes, applied: applied)
        end

        def applied_discount(node)
          Portage::Ucp::AppliedDiscount.new(
            title: node["title"] || node["code"],
            amount: minor_units(node["discountedAmount"]),
            code: node["code"],
            automatic: !node["code"]
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
            totals: Portage::Ucp::Support::Totals.line(line_total)
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
            order: order,
            discounts: discounts(node),
            fulfillment: checkout_fulfillment(node)
          )
        end

        # dev.ucp.shopping.fulfillment (pre-purchase shipping-option
        # selection) built from Cart#deliveryGroups — read straight off
        # CART_FIELDS, no separate query. Shopify has no "fulfillment method"
        # grouping above deliveryGroups, and a cart only ever carries the one
        # buyer-submitted address (split-shipment-to-multiple-addresses isn't
        # modeled here), so every deliveryGroup collapses into a single
        # synthesized FulfillmentMethod rather than one per Shopify group.
        def checkout_fulfillment(node)
          groups_nodes = node["deliveryGroups"] || []
          return Portage::Ucp::CheckoutFulfillment.new if groups_nodes.empty?

          groups = groups_nodes.map { |g| fulfillment_group(g) }
          destination = shipping_destination(groups_nodes.first["deliveryAddress"])
          method = Portage::Ucp::FulfillmentMethod.new(
            id: "fm_#{node['id']}",
            type: DELIVERY_METHOD_TYPES.fetch(groups_nodes.first.dig("deliveryOptions", 0, "deliveryMethodType"),
                                              "shipping"),
            line_item_ids: groups.flat_map(&:line_item_ids),
            destinations: destination ? [destination] : [],
            selected_destination_id: destination&.id,
            groups: groups
          )
          Portage::Ucp::CheckoutFulfillment.new(shipping_methods: [method])
        end

        def fulfillment_group(node)
          Portage::Ucp::FulfillmentGroup.new(
            id: node["id"],
            line_item_ids: (node.dig("cartLines", "nodes") || []).map { |n| n["id"] },
            options: (node["deliveryOptions"] || []).map { |o| fulfillment_option(o) },
            selected_option_id: node.dig("selectedDeliveryOption", "handle")
          )
        end

        def fulfillment_option(node)
          Portage::Ucp::FulfillmentOption.new(
            id: node["handle"], title: node["title"] || node["handle"],
            totals: [Portage::Ucp::Total.new(type: "total", amount: minor_units(node["estimatedCost"]))],
            description: node["description"]
          )
        end

        # Shopify's CartDeliveryGroup#deliveryAddress is a bare MailingAddress
        # with no id of its own (unlike a saved address-book entry) — since a
        # cart only ever carries the one buyer-submitted address (see
        # #checkout_fulfillment), this always exposes it as the single
        # destination "current" rather than fabricating a hash-based id that
        # would drift for no real change.
        def shipping_destination(address_node)
          return nil unless address_node

          Portage::Ucp::ShippingDestination.new(id: "current",
                                                address: Portage::Ucp::PostalAddress.new(**fulfillment_address(address_node)))
        end

        def fulfillment_address(node)
          { street_address: node["address1"], extended_address: node["address2"], address_locality: node["city"],
            address_region: node["provinceCode"], address_country: node["countryCode"], postal_code: node["zip"],
            first_name: node["firstName"], last_name: node["lastName"], phone_number: node["phone"] }.compact
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
            totals: Portage::Ucp::Support::Totals.summary(subtotal: subtotal_amount, total: total_amount),
            adjustments: adjustments(node)
          )
        end

        # cancel_order/refund_order/request_return (design-log §16) don't map
        # to a dedicated Shopify response shape each — they all resolve back
        # to a fresh GET_ORDER read, so the order's cancellation/refund/return
        # state is read straight off the Order node here rather than
        # synthesized ad hoc per adapter method.
        def adjustments(node)
          [
            *(node["cancelledAt"] ? [cancellation_adjustment(node)] : []),
            *(node["refunds"] || []).map { |n| refund_adjustment(n) },
            *(node.dig("returns", "nodes") || []).map { |n| return_adjustment(n) }
          ]
        end

        def cancellation_adjustment(node)
          Portage::Ucp::Adjustment.new(
            id: "#{node['id']}-cancellation", type: "cancellation", occurred_at: node["cancelledAt"],
            status: "completed", description: node["cancelReason"]
          )
        end

        def refund_adjustment(node)
          line_items = (node.dig("refundLineItems", "nodes") || []).map { |n| order_line_ref(n, -n["quantity"]) }
          Portage::Ucp::Adjustment.new(
            id: node["id"], type: "refund", occurred_at: node["createdAt"], status: "completed",
            line_items: line_items.empty? ? nil : line_items,
            totals: [Portage::Ucp::Total.new(type: "total", amount: -minor_units(node.dig("totalRefundedSet",
                                                                                          "shopMoney")))],
            description: node["note"]
          )
        end

        # Shopify's ReturnStatus enum (OPEN/REQUESTED/CLOSED/DECLINED/
        # CANCELED/...); unmapped values fall back to "pending", same
        # unmapped-enum posture as DELIVERY_METHOD_TYPES/
        # FULFILLMENT_EVENT_TYPES below.
        RETURN_STATUSES = {
          "OPEN" => "pending", "REQUESTED" => "pending", "CLOSED" => "completed",
          "DECLINED" => "failed", "CANCELED" => "failed"
        }.freeze

        def return_adjustment(node)
          line_items = (node.dig("returnLineItems", "nodes") || []).map do |n|
            { "id" => n.dig("fulfillmentLineItem", "lineItem", "id"), "quantity" => -n["quantity"] }
          end
          description = node.dig("returnLineItems", "nodes")&.first&.fetch("returnReasonNote", nil)
          Portage::Ucp::Adjustment.new(
            id: node["id"], type: "return", occurred_at: node["requestedAt"],
            status: RETURN_STATUSES.fetch(node["status"], "pending"),
            line_items: line_items.empty? ? nil : line_items, description: description
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
            totals: Portage::Ucp::Support::Totals.line(line_total),
            status: Portage::Ucp::Support::LineItemStatus.derive(total: total, fulfilled: fulfilled)
          )
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

        # Builds the top-level totals array from Shopify's cost breakdown.
        def totals(node)
          cost = node["cost"]
          Portage::Ucp::Support::Totals.summary(subtotal: minor_units(cost["subtotalAmount"]),
                                                tax: minor_units(cost["totalTaxAmount"]),
                                                total: minor_units(cost["totalAmount"]))
        end
      end
    end
  end
end
