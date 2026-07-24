require "bigdecimal"

module UcpMcp
  module Shopify
    # Converts Shopify GraphQL response nodes into the protocol-layer value
    # objects from UcpMcp::ValueObjects (Product/Cart/LineItem/Checkout/Order/
    # Money) — nothing Shopify-shaped is allowed to leak past this file.
    #
    # UCP's LineItem#item.id is Shopify's variant GID, not the parent
    # product's GID: Shopify carts hold variants (a specific size/color), and
    # a product with one variant just uses that variant's id.
    module Mapper
      module_function

      def money(price)
        UcpMcp::Money.new(amount_minor: (BigDecimal(price["amount"]) * 100).to_i, currency: price["currencyCode"])
      end

      def minor_units(price)
        (BigDecimal(price["amount"]) * 100).to_i
      end

      def product(node)
        UcpMcp::Product.new(
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
        UcpMcp::Cart.new(
          id: node["id"],
          line_items: node.dig("lines", "nodes").map { |n| cart_line_item(n) },
          currency: node.dig("cost", "subtotalAmount", "currencyCode"),
          totals: totals(node)
        )
      end

      def cart_line_item(node)
        merchandise = node["merchandise"]
        line_total = minor_units(node.dig("cost", "totalAmount"))
        UcpMcp::LineItem.new(
          id: node["id"],
          item: UcpMcp::Item.new(id: merchandise["id"], title: merchandise.dig("product", "title"),
                                 price: minor_units(merchandise["price"])),
          quantity: node["quantity"],
          totals: [UcpMcp::Total.new(type: "subtotal", amount: line_total),
                   UcpMcp::Total.new(type: "total", amount: line_total)]
        )
      end

      # `status` isn't a Shopify Cart field — Cart/Checkout is one object in
      # Shopify's model, so the adapter tracks status itself across the
      # create/update/complete/cancel lifecycle and passes it in here.
      def checkout(node, status:)
        UcpMcp::Checkout.new(
          id: node["id"],
          status: status,
          line_items: node.dig("lines", "nodes").map { |n| cart_line_item(n) },
          currency: node.dig("cost", "subtotalAmount", "currencyCode"),
          totals: totals(node),
          links: []
        )
      end

      # NOTE: `checkout_id` is required by the real schema for
      # checkout/order reconciliation, but Shopify's Order type has no field
      # linking back to the originating cart/checkout — there's nothing to
      # map it from. Left blank until Shopify exposes one (or this adapter
      # tracks the cart->order link itself, the way @checkout_status already
      # tracks cart->checkout status). `fulfillment` is similarly left as an
      # empty object: expectations/events aren't required by the schema, and
      # modeling Shopify's `fulfillments`/`fulfillmentOrders` into UCP's
      # buyer-facing expectation/event shape is real work, tracked
      # separately rather than guessed at here.
      def order(node)
        total_amount = minor_units(node.dig("currentTotalPriceSet", "shopMoney"))
        UcpMcp::Order.new(
          id: node["id"],
          checkout_id: "",
          permalink_url: node["statusPageUrl"],
          line_items: node.dig("lineItems", "nodes").map { |n| order_line_item(n) },
          fulfillment: {},
          currency: node.dig("currentTotalPriceSet", "shopMoney", "currencyCode"),
          totals: [UcpMcp::Total.new(type: "total", amount: total_amount)]
        )
      end

      def order_line_item(node)
        variant_node = node["variant"]
        line_total = minor_units(node.dig("discountedTotalSet", "shopMoney"))
        total = node["currentQuantity"]
        fulfilled = total - node["unfulfilledQuantity"]
        UcpMcp::OrderLineItem.new(
          id: node["id"],
          item: UcpMcp::Item.new(id: variant_node && variant_node["id"], title: variant_node && variant_node["title"],
                                 price: variant_node && minor_units(variant_node["price"])),
          quantity: { original: node["quantity"], total: total, fulfilled: fulfilled },
          totals: [UcpMcp::Total.new(type: "subtotal", amount: line_total),
                   UcpMcp::Total.new(type: "total", amount: line_total)],
          status: order_line_item_status(total, fulfilled)
        )
      end

      def order_line_item_status(total, fulfilled)
        return "removed" if total.zero?
        return "fulfilled" if fulfilled == total
        return "partial" if fulfilled.positive?

        "processing"
      end

      # Builds the top-level totals array (exactly one subtotal + one total,
      # plus an optional tax entry) from Shopify's cost breakdown.
      def totals(node)
        cost = node["cost"]
        entries = [UcpMcp::Total.new(type: "subtotal", amount: minor_units(cost["subtotalAmount"]))]
        tax = minor_units(cost["totalTaxAmount"])
        entries << UcpMcp::Total.new(type: "tax", amount: tax) if tax.positive?
        entries << UcpMcp::Total.new(type: "total", amount: minor_units(cost["totalAmount"]))
        entries
      end
    end
  end
end
