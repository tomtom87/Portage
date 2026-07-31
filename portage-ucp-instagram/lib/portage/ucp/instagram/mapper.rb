require "bigdecimal"

module Portage
  module Ucp
    module Instagram
      # Converts Meta Graph API Commerce Catalog/Orders response bodies
      # into the protocol-layer value objects from
      # Portage::Ucp::ValueObjects — nothing Meta-shaped is allowed to leak
      # past this file.
      module Mapper
        module_function

        AVAILABLE_STATES = ["in stock", "available for order", "preorder"].freeze

        # Meta's Catalog product `price` field is a single string combining
        # amount and currency (`"25.00 USD"`), unlike every REST-based
        # adapter in this project splitting those into separate fields —
        # this is the one place that string needs parsing.
        def money(price_string)
          return Portage::Ucp::Money.new(amount_minor: 0, currency: nil) unless price_string

          amount, currency = price_string.split
          money_from_parts(amount, currency)
        end

        # Unlike the catalog Product's combined `"25.00 USD"` price
        # string, the Commerce Orders API's amounts come as separate
        # `amount`/`currency` fields — this is the shape #order and
        # #order_line_item work with.
        def money_from_parts(amount, currency)
          return Portage::Ucp::Money.new(amount_minor: 0, currency: currency) unless amount

          Portage::Ucp::Money.new(amount_minor: (BigDecimal(amount.to_s) * 100).to_i, currency: currency)
        end

        # `node["variants_detail"]` is adapter-populated, not a real Meta
        # field: variants of a catalog product are just *other whole
        # product nodes* sharing the same `item_group_id` — there's no
        # nested variant array to read off a single product the way
        # Shopify/BigCommerce have one. Fetching the group's other members
        # is a second call, made only for #get_product's single-product
        # path, same N+1 reasoning as every other adapter's variant fetch.
        def product(node, site_url: nil)
          Portage::Ucp::Product.new(
            id: node["id"],
            title: node["name"],
            description: node["description"],
            price: money(node["price"]),
            available: AVAILABLE_STATES.include?(node["availability"]),
            variants: variants(node),
            url: node["url"] || site_url
          )
        end

        # A product with no `item_group_id` siblings is its own single
        # implicit variant, same as a single-variant Shopify product using
        # that variant's own id.
        def variants(node)
          detail = node["variants_detail"]
          return [variant(node)] unless detail

          detail.map { |v| variant(v) }
        end

        def variant(node)
          { id: node["id"], title: node["name"], available: AVAILABLE_STATES.include?(node["availability"]),
            price: money(node["price"]) }
        end

        # `id:` is caller-supplied: there's no real Meta checkout resource
        # behind this at all for "checkout on your website" catalogs — see
        # Portage::Ucp::Instagram::Adapter's class-level comment. `links`
        # points at each product's own `url` (the merchant's own product
        # page) rather than a cart, since Instagram/Facebook's public API
        # has no way to deep-link a multi-item add-to-cart flow outside
        # Meta's own native checkout.
        def checkout(products, id:, status:)
          line_items = products.map { |p| checkout_line_item(p) }
          Portage::Ucp::Checkout.new(
            id: id,
            status: status,
            line_items: line_items,
            currency: products.first && money(products.first["price"]).currency,
            totals: totals(products),
            links: products.map { |p| Portage::Ucp::Link.new(type: "checkout", url: p["url"], title: p["name"]) }
          )
        end

        def checkout_line_item(node)
          unit_price = money(node["price"]).amount_minor
          quantity = node["quantity"] || 1
          line_total = unit_price * quantity
          Portage::Ucp::LineItem.new(
            id: node["id"],
            item: Portage::Ucp::Item.new(id: node["id"], title: node["name"], price: unit_price),
            quantity: quantity,
            totals: [Portage::Ucp::Total.new(type: "subtotal", amount: line_total),
                     Portage::Ucp::Total.new(type: "total", amount: line_total)]
          )
        end

        def totals(products)
          subtotal = products.sum { |p| money(p["price"]).amount_minor * (p["quantity"] || 1) }
          [Portage::Ucp::Total.new(type: "subtotal", amount: subtotal),
           Portage::Ucp::Total.new(type: "total", amount: subtotal)]
        end

        # Meta's Commerce Order resource only exists at all for "Checkout on
        # Instagram/Facebook" merchants — merchants using "checkout on your
        # website" (the population Checkout#links above is built for) never
        # have a Meta-side order; their orders live entirely in their own
        # system (e.g. via the Shopify/WooCommerce/etc adapter for that
        # side), and this method will 403/404 for them. `permalink_url` is
        # left blank — Meta doesn't return a buyer-facing order link via
        # this API. `checkout_id` is always blank too, same fundamental
        # reason as Portage::Ucp::Etsy::Mapper.order.
        ORDER_STATUS = { "COMPLETED" => "fulfilled", "CANCELLED" => "removed" }.freeze

        def order(node)
          status = ORDER_STATUS.fetch(node.dig("order_status", "state"), "processing")
          items = node.dig("items", "data") || []
          subtotal = money_from_parts(node.dig("estimated_payment_details", "subtotal", "amount"), nil).amount_minor
          total = money_from_parts(node.dig("estimated_payment_details", "total_amount", "amount"), nil).amount_minor
          Portage::Ucp::Order.new(
            id: node["id"],
            checkout_id: "",
            permalink_url: "",
            line_items: items.map { |n| order_line_item(n, status) },
            fulfillment: {},
            currency: node.dig("estimated_payment_details", "total_amount", "currency"),
            totals: [Portage::Ucp::Total.new(type: "subtotal", amount: subtotal),
                     Portage::Ucp::Total.new(type: "total", amount: total)]
          )
        end

        def order_line_item(node, status)
          quantity = node["quantity"]
          fulfilled = status == "fulfilled" ? quantity : 0
          unit_price = money_from_parts(node.dig("price_per_unit", "amount"), nil).amount_minor
          line_total = unit_price * quantity
          Portage::Ucp::OrderLineItem.new(
            id: node["id"].to_s,
            item: Portage::Ucp::Item.new(id: node["retailer_id"].to_s, title: node["product_name"],
                                         price: unit_price),
            quantity: { original: quantity, total: quantity, fulfilled: fulfilled },
            totals: [Portage::Ucp::Total.new(type: "subtotal", amount: line_total),
                     Portage::Ucp::Total.new(type: "total", amount: line_total)],
            status: status
          )
        end
      end
    end
  end
end
