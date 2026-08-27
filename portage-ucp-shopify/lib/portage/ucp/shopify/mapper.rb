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

        # dev.ucp.shopping.catalog's Price (types/price.json) — the
        # wire-shape counterpart to #money above, used everywhere a Product/
        # Variant field carries currency directly rather than through the
        # arithmetic-only Money type.
        def price(node)
          Portage::Ucp::Price.new(amount: minor_units(node), currency: node["currencyCode"])
        end

        def product(node)
          currency = node.dig("priceRange", "minVariantPrice", "currencyCode")
          Portage::Ucp::Product.new(
            id: node["id"],
            handle: node["handle"],
            title: node["title"],
            description: description(node),
            price_range: price_range(node["priceRange"]),
            list_price_range: compare_at_price_range(node["compareAtPriceRange"]),
            variants: node.dig("variants", "nodes").map { |v| variant(v, description(node), currency) },
            options: (node["options"] || []).map { |o| product_option(o) },
            media: product_media(node.dig("featuredMedia", "nodes", 0)),
            tags: node["tags"] || [],
            url: node["onlineStoreUrl"],
            metadata: metafields_metadata(node["metafields"], :product)
          )
        end

        # Shopify's `type` tags a metafield with one of ~20 encodings
        # (design-log §20 handoff). Only the ones where passing the raw
        # string through would be actively wrong for an agent to consume get
        # parsed here — `json`, `dimension`/`measurement` (both
        # `{"value":..,"unit":..}`-shaped JSON strings), and any `list.*`
        # (a JSON array of the scalar type). Everything else (plain text,
        # numbers, dates, refs, ...) passes through as Shopify sent it.
        METAFIELD_JSON_TYPES = %w[json dimension measurement].freeze

        def parse_metafield_value(value, type)
          return JSON.parse(value) if METAFIELD_JSON_TYPES.include?(type) || type&.start_with?("list.")

          value
        end

        # `metafields` is nil when nothing's configured for `scope` (the
        # fragment itself was omitted from the query — see
        # Queries.metafields_fragment) — that's the common case and returns
        # nil rather than {}, matching Product/Variant#metadata's own
        # nil-by-default. Otherwise it's Shopify's `metafields(identifiers:)`
        # array, positional against the same
        # `Portage::Ucp::Shopify.configuration.fields_for(scope)` list the
        # query was built from, with a nil entry wherever that metafield
        # isn't set on this product/variant.
        def metafields_metadata(metafields, scope)
          return nil if metafields.nil?

          fields = Portage::Ucp::Shopify.configuration.fields_for(scope)
          metadata = fields.zip(metafields).each_with_object({}) do |(field, metafield), acc|
            next unless field && metafield && metafield["value"]

            acc[field[:key]] = parse_metafield_value(metafield["value"], metafield["type"])
          end
          metadata.empty? ? nil : metadata
        end

        def description(node)
          Portage::Ucp::Description.new(plain: node["description"], html: node["descriptionHtml"])
        end

        def price_range(node)
          Portage::Ucp::PriceRange.new(min: price(node["minVariantPrice"]), max: price(node["maxVariantPrice"]))
        end

        # nil when Shopify's compareAtPriceRange itself is nil (no variant
        # has a compare-at price set) rather than a zeroed-out range —
        # Product#list_price_range is optional, so "no strikethrough price"
        # should mean the field is absent, not present-and-zero.
        def compare_at_price_range(node)
          return nil unless node

          Portage::Ucp::PriceRange.new(min: price(node["minVariantCompareAtPrice"]),
                                       max: price(node["maxVariantCompareAtPrice"]))
        end

        def product_option(node)
          values = (node["optionValues"] || []).map { |v| Portage::Ucp::OptionValue.new(id: v["id"], label: v["name"]) }
          Portage::Ucp::ProductOption.new(name: node["name"], values: values)
        end

        def product_media(node)
          image = node && node["image"]
          return [] unless image

          [Portage::Ucp::Media.new(type: "image", url: image["url"], alt_text: image["altText"],
                                   width: image["width"], height: image["height"])]
        end

        # `barcode` is a single untyped Shopify string with no declared
        # standard — inferred from length rather than asserted, since
        # Shopify doesn't tag which GS1 standard (UPC-A/EAN-13/EAN-8) a
        # given value follows. Anything else (an internal SKU-shaped
        # barcode, a non-numeric value) is passed through as bare "GTIN"
        # rather than dropped, so the field still reaches the agent.
        BARCODE_TYPES = { 8 => "EAN", 12 => "UPC", 13 => "EAN" }.freeze

        def barcodes(value)
          return [] if value.nil? || value.empty?

          [{ "type" => BARCODE_TYPES.fetch(value.length, "GTIN"), "value" => value }]
        end

        # `product_description` is the parent Product's own Description —
        # Shopify's ProductVariant has no description field of its own, and
        # types/variant.json requires one, so this reuses the product's, same
        # posture as Wix's variant title falling back to its product's (see
        # Portage::Ucp::Wix::Mapper#variant).
        # `price`/`compareAtPrice` come back as the bare `Money` scalar (a
        # decimal string, no currency of its own) rather than a MoneyV2
        # object — confirmed against the live Admin API 2026-04 schema, which
        # rejects `{ amount currencyCode }` sub-selections on them. `currency`
        # is the product's own (from priceRange), which every variant shares.
        def scalar_price(amount, currency)
          Portage::Ucp::Price.new(amount: Portage::Ucp::Support::Amounts.decimal_to_minor(amount), currency: currency)
        end

        def variant(node, product_description, currency)
          Portage::Ucp::Variant.new(
            id: node["id"],
            title: node["title"],
            description: product_description,
            price: scalar_price(node["price"], currency),
            sku: node["sku"],
            barcodes: barcodes(node["barcode"]),
            list_price: node["compareAtPrice"] && scalar_price(node["compareAtPrice"], currency),
            availability: { "available" => node["availableForSale"] },
            options: selected_options(node["selectedOptions"]),
            media: variant_media(node["image"]),
            metadata: metafields_metadata(node["metafields"], :variant)
          )
        end

        def selected_options(nodes)
          (nodes || []).map { |o| Portage::Ucp::SelectedOption.new(name: o["name"], label: o["value"]) }
        end

        def variant_media(image)
          return [] unless image

          [Portage::Ucp::Media.new(type: "image", url: image["url"], alt_text: image["altText"],
                                   width: image["width"], height: image["height"])]
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
          groups_nodes = node.dig("deliveryGroups", "nodes") || []
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
        # `totalTaxAmount` is nullable on a real cart — Shopify doesn't
        # compute tax until it has enough context (a shipping address, a
        # tax-registered market), so a fresh cart genuinely has no tax
        # amount yet rather than a zero one. Confirmed live against
        # ucp-test-bc2vif1p.myshopify.com (design-log §17).
        def totals(node)
          cost = node["cost"]
          tax = cost["totalTaxAmount"]
          Portage::Ucp::Support::Totals.summary(subtotal: minor_units(cost["subtotalAmount"]),
                                                tax: tax ? minor_units(tax) : 0,
                                                total: minor_units(cost["totalAmount"]))
        end
      end
    end
  end
end
