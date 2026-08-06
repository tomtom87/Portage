require "bigdecimal"

module Portage
  module Ucp
    module BigCommerce
      # Converts BigCommerce Admin API response bodies (v3 Catalog/Carts/
      # Checkouts, v2 Orders) into the protocol-layer value objects from
      # Portage::Ucp::ValueObjects — nothing BigCommerce-shaped is allowed to
      # leak past this file.
      #
      # `currency` is threaded in by the caller everywhere it's needed: the
      # v3 Catalog product resource doesn't carry a currency field at all
      # (it's a store-wide default currency setting), unlike Cart/Checkout
      # responses, which carry their own `currency.code`.
      module Mapper
        module_function

        def money(amount, currency)
          Portage::Ucp::Money.new(amount_minor: minor_units(amount), currency: currency)
        end

        def minor_units(amount)
          return 0 if amount.nil? || amount == ""

          (BigDecimal(amount.to_s) * 100).to_i
        end

        # `site_url` is only used to turn `custom_url.url` (always store-
        # relative, e.g. "/cold-brew/") into an absolute product URL — the v3
        # Catalog resource never returns an absolute one itself.
        def product(node, currency:, site_url:)
          Portage::Ucp::Product.new(
            id: node["id"].to_s,
            title: node["name"],
            description: node["description"],
            price: money(node["price"], currency),
            available: node["availability"] != "disabled",
            variants: variants(node, currency),
            url: node.dig("custom_url", "url") ? "#{site_url}#{node.dig('custom_url', 'url')}" : nil
          )
        end

        # A product with no configured variants has no real Catalog
        # "variants" entries at all — it's its own single implicit variant,
        # same as Portage::Ucp::WooCommerce::Mapper.variants for a simple product.
        def variants(node, currency)
          nodes = node["variants"]
          unless nodes&.any?
            return [{ id: node["id"].to_s, title: node["name"], available: node["availability"] != "disabled",
                      price: money(node["price"], currency) }]
          end

          nodes.map { |v| variant(v, node, currency) }
        end

        # A variant's own `price` is 0/null when it doesn't override the
        # base product price — falls back to the parent product's price in
        # that case, same "inherits unless overridden" rule BigCommerce
        # documents for variant pricing.
        def variant(node, parent_node, currency)
          title = (node["option_values"] || []).map { |ov| ov["label"] }.join(" / ")
          price = node["price"].to_f.zero? ? parent_node["price"] : node["price"]
          { id: node["id"].to_s, title: title, available: !node["purchasing_disabled"], price: money(price, currency) }
        end

        # `id:` is caller-supplied rather than read off the response body's
        # own top-level id in every call site: a v3 Cart's `id` field is a
        # real, stable resource id (unlike WooCommerce's headerless Cart-
        # Token), but callers pass it explicitly anyway so Adapter can reuse
        # this same method for both the cart-creation response (id known
        # from the body) and a checkout's embedded `cart` sub-object (no
        # top-level id of its own).
        def cart(node, id:)
          currency = node.dig("currency", "code")
          items = (node.dig("line_items", "physical_items") || []) + (node.dig("line_items", "digital_items") || [])
          Portage::Ucp::Cart.new(
            id: id,
            line_items: items.map { |n| cart_line_item(n) },
            currency: currency,
            totals: [Portage::Ucp::Total.new(type: "subtotal", amount: minor_units(node["base_amount"])),
                     Portage::Ucp::Total.new(type: "total", amount: minor_units(node["cart_amount"]))]
          )
        end

        # `status` isn't a v3 Checkout field either — BigCommerce's Checkout
        # is the cart plus billing/consignment/order-linkage data, not a
        # resource with its own lifecycle enum, so the Adapter tracks status
        # itself and passes it in, same rationale as
        # Portage::Ucp::Shopify::Mapper.checkout and Portage::Ucp::WooCommerce::Mapper.checkout.
        def checkout(node, id:, status:, order: nil)
          cart_node = node["cart"] || node

          Portage::Ucp::Checkout.new(
            id: id,
            status: status,
            line_items: cart(cart_node, id: id).line_items,
            currency: cart_node.dig("currency", "code"),
            totals: checkout_totals(node, cart_node),
            links: [],
            order: order
          )
        end

        def checkout_totals(node, cart_node)
          totals = [Portage::Ucp::Total.new(type: "subtotal",
                                            amount: minor_units(node["subtotal"] || cart_node["base_amount"]))]
          tax = minor_units(node["tax_total"])
          totals << Portage::Ucp::Total.new(type: "tax", amount: tax) if tax.positive?
          totals << Portage::Ucp::Total.new(type: "total",
                                            amount: minor_units(node["grand_total"] || cart_node["cart_amount"]))
          totals
        end

        # CAVEAT: assumes physical/digital cart line items carry plain
        # decimal price fields (`sale_price`, `extended_sale_price`), the
        # shape BigCommerce's own docs show — not confirmed against a live
        # cart response, which some BigCommerce API surfaces instead nest
        # under a `{value:, currency:}` sub-object.
        def cart_line_item(node)
          unit_price = minor_units(node["sale_price"])
          line_total = minor_units(node["extended_sale_price"])
          Portage::Ucp::LineItem.new(
            id: node["id"],
            item: Portage::Ucp::Item.new(id: (node["variant_id"] || node["product_id"]).to_s, title: node["name"],
                                         price: unit_price, image_url: node["image_url"]),
            quantity: node["quantity"],
            totals: [Portage::Ucp::Total.new(type: "subtotal", amount: minor_units(node["extended_list_price"])),
                     Portage::Ucp::Total.new(type: "total", amount: line_total)]
          )
        end

        # BigCommerce's fixed, store-independent order status_id enum — see
        # https://developer.bigcommerce.com/docs/rest-management/order-statuses.
        # Core has no per-line-item fulfillment tracking (that's a shipping-
        # app concern), so every order line is given the same coarse status
        # derived from the order's own top-level status, same posture as
        # Portage::Ucp::WooCommerce::Mapper::ORDER_LINE_ITEM_STATUS.
        ORDER_STATUS = {
          2 => "fulfilled", 8 => "fulfilled", 10 => "fulfilled",
          4 => "removed", 5 => "removed", 6 => "removed", 14 => "removed"
        }.freeze

        # `permalink_url` is built from BigCommerce's documented storefront
        # order-status route — not confirmed against a live storefront theme,
        # same "needs confirming" posture as
        # Portage::Ucp::WooCommerce::Mapper.order's order-received URL.
        #
        # `products` is the separate v2 `/orders/{id}/products` response —
        # unlike WooCommerce/Shopify, a v2 Order's own resource doesn't embed
        # its line items, so the Adapter fetches and merges them in.
        def order(node, products:, site_url:, checkout_id: "")
          currency = node["currency_code"]
          status = ORDER_STATUS.fetch(node["status_id"], "processing")
          Portage::Ucp::Order.new(
            id: node["id"].to_s,
            checkout_id: checkout_id,
            permalink_url: "#{site_url}/account.php?action=order_status&order_id=#{node['id']}",
            line_items: products.map { |n| order_line_item(n, status) },
            fulfillment: Portage::Ucp::Fulfillment.new,
            currency: currency,
            totals: [Portage::Ucp::Total.new(type: "subtotal", amount: minor_units(node["subtotal_ex_tax"])),
                     Portage::Ucp::Total.new(type: "total", amount: minor_units(node["total_inc_tax"]))]
          )
        end

        def order_line_item(node, status)
          quantity = node["quantity"]
          fulfilled = status == "fulfilled" ? quantity : 0
          Portage::Ucp::OrderLineItem.new(
            id: node["id"].to_s,
            item: Portage::Ucp::Item.new(id: node["product_id"].to_s, title: node["name"],
                                         price: minor_units(node["price_ex_tax"])),
            quantity: { original: quantity, total: quantity, fulfilled: fulfilled },
            totals: [Portage::Ucp::Total.new(type: "subtotal", amount: minor_units(node["total_ex_tax"])),
                     Portage::Ucp::Total.new(type: "total", amount: minor_units(node["total_inc_tax"]))],
            status: status
          )
        end
      end
    end
  end
end
