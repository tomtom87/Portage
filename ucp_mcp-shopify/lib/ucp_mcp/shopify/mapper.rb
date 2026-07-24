require "bigdecimal"

module UcpMcp
  module Shopify
    # Converts Shopify GraphQL response nodes into the protocol-layer value
    # objects from UcpMcp::ValueObjects (Product/Cart/LineItem/Checkout/Order/
    # Money) — nothing Shopify-shaped is allowed to leak past this file.
    #
    # UCP's "product_id" on a LineItem is Shopify's variant GID, not the
    # parent product's GID: Shopify carts hold variants (a specific size/
    # color), and a product with one variant just uses that variant's id.
    module Mapper
      module_function

      def money(price)
        UcpMcp::Money.new(amount_minor: (BigDecimal(price["amount"]) * 100).to_i, currency: price["currencyCode"])
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
        line_items = node.dig("lines", "nodes").map { |n| cart_line_item(n) }
        UcpMcp::Cart.new(
          id: node["id"],
          line_items: line_items,
          subtotal: money(node.dig("cost", "subtotalAmount")),
          currency: node.dig("cost", "subtotalAmount", "currencyCode")
        )
      end

      def cart_line_item(node)
        merchandise = node["merchandise"]
        UcpMcp::LineItem.new(
          id: node["id"],
          product_id: merchandise["id"],
          quantity: node["quantity"],
          unit_price: money(merchandise["price"]),
          total: money(node.dig("cost", "totalAmount"))
        )
      end

      # `status` isn't a Shopify Cart field — Cart/Checkout is one object in
      # Shopify's model, so the adapter tracks status itself across the
      # create/update/complete lifecycle and passes it in here.
      def checkout(node, status:)
        cart_value = cart(node)
        UcpMcp::Checkout.new(
          id: cart_value.id,
          status: status,
          line_items: cart_value.line_items,
          subtotal: cart_value.subtotal,
          tax: money(node.dig("cost", "totalTaxAmount")),
          total: money(node.dig("cost", "totalAmount")),
          currency: cart_value.currency,
          locale: "en-US",
          available_payment_handlers: []
        )
      end

      def order(node)
        UcpMcp::Order.new(
          id: node["id"],
          status: node["displayFulfillmentStatus"],
          line_items: node.dig("lineItems", "nodes").map { |n| order_line_item(n) },
          total: money(node.dig("currentTotalPriceSet", "shopMoney")),
          currency: node.dig("currentTotalPriceSet", "shopMoney", "currencyCode"),
          placed_at: node["createdAt"]
        )
      end

      def order_line_item(node)
        variant_node = node["variant"]
        UcpMcp::LineItem.new(
          id: node["id"],
          product_id: variant_node && variant_node["id"],
          quantity: node["quantity"],
          unit_price: variant_node && money(variant_node["price"]),
          total: money(node.dig("discountedTotalSet", "shopMoney"))
        )
      end
    end
  end
end
