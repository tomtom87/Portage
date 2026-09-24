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

        # A bare decimal, optionally followed by a currency code — anything
        # else (an empty amount, "N/A", a stray currency symbol) is treated
        # as unparseable rather than handed to BigDecimal, which raises
        # ArgumentError on anything that isn't a valid decimal literal. A
        # single malformed price on one product/order shouldn't blow up an
        # entire catalog search or order fetch.
        AMOUNT_PATTERN = /\A-?\d+(\.\d+)?\z/

        # Meta's Catalog product `price` field is a single string combining
        # amount and currency (`"25.00 USD"`), unlike every REST-based
        # adapter in this project splitting those into separate fields —
        # this is the one place that string needs parsing. A currency-less
        # string (`"25.00"`, no space) splits to a nil currency, same as a
        # currency Meta never sent.
        def money(price_string)
          return Portage::Ucp::Money.new(amount_minor: 0, currency: nil) unless price_string

          amount, currency = price_string.to_s.split
          money_from_parts(amount, currency)
        end

        # Unlike the catalog Product's combined `"25.00 USD"` price
        # string, the Commerce Orders API's amounts come as separate
        # `amount`/`currency` fields — this is the shape #order and
        # #order_line_item work with.
        def money_from_parts(amount, currency)
          Portage::Ucp::Support::Amounts.money(safe_amount(amount), currency)
        end

        def description(node)
          Portage::Ucp::Description.new(plain: node["description"])
        end

        def price(price_string)
          return Portage::Ucp::Price.new(amount: 0, currency: nil) unless price_string

          amount, currency = price_string.to_s.split
          Portage::Ucp::Price.new(amount: Portage::Ucp::Support::Amounts.decimal_to_minor(safe_amount(amount)),
                                  currency: currency)
        end

        # nil in, nil out (Support::Amounts already treats a nil amount as
        # zero); a non-numeric string in, nil out, so it's treated the same
        # way rather than raising.
        def safe_amount(amount)
          amount if amount.nil? || (amount.is_a?(String) && amount.match?(AMOUNT_PATTERN))
        end

        def price_range(price_string)
          p = price(price_string)
          Portage::Ucp::PriceRange.new(min: p, max: p)
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
            description: description(node),
            price_range: price_range(node["price"]),
            variants: variants(node),
            url: node["url"] || site_url
          )
        end

        # A product with no `item_group_id` siblings is its own single
        # implicit variant, same as a single-variant Shopify product using
        # that variant's own id.
        def variants(node)
          detail = node["variants_detail"]
          return [variant(node, node)] unless detail

          detail.map { |v| variant(v, node) }
        end

        def variant(node, parent_node)
          Portage::Ucp::Variant.new(
            id: node["id"], title: node["name"], description: description(parent_node), price: price(node["price"]),
            availability: { "available" => AVAILABLE_STATES.include?(node["availability"]) }
          )
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
            totals: Portage::Ucp::Support::Totals.line(line_total)
          )
        end

        def totals(products)
          subtotal = products.sum { |p| money(p["price"]).amount_minor * (p["quantity"] || 1) }
          Portage::Ucp::Support::Totals.summary(subtotal: subtotal, total: subtotal)
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
          status = Portage::Ucp::Support::LineItemStatus.from_table(ORDER_STATUS, order_status_state(node))
          Portage::Ucp::Order.new(
            id: node["id"],
            checkout_id: "",
            permalink_url: "",
            line_items: order_items(node).map { |n| order_line_item(n, status) },
            fulfillment: Portage::Ucp::Fulfillment.new,
            currency: safe_dig(node, "estimated_payment_details", "total_amount", "currency"),
            totals: order_totals(node)
          )
        end

        def order_status_state(node)
          safe_dig(node, "order_status", "state")
        end

        def order_totals(node)
          subtotal = money_from_parts(safe_dig(node, "estimated_payment_details", "subtotal", "amount"),
                                      nil).amount_minor
          total = money_from_parts(safe_dig(node, "estimated_payment_details", "total_amount", "amount"),
                                   nil).amount_minor
          Portage::Ucp::Support::Totals.summary(subtotal: subtotal, total: total)
        end

        # `node["items"]["data"]` absent entirely (no items field), present
        # but empty (an order with no line items), or malformed (either
        # level not the Hash/Array Meta's documented shape promises) all
        # degrade to "no line items" rather than raising. Individual
        # elements of `data` are validated too: `data.grep(Hash)` drops any
        # non-Hash entry (nil, a bare string, etc.) so #order_line_item
        # never has to handle a non-Hash `node`.
        def order_items(node)
          items = node["items"]
          return [] unless items.is_a?(Hash)

          data = items["data"]
          data.is_a?(Array) ? data.grep(Hash) : []
        end

        # A nested `.dig` chain raises TypeError the moment an intermediate
        # value isn't a Hash (e.g. Meta sending `estimated_payment_details`
        # as something other than the documented object) — this stops at
        # nil instead, same "degrade, don't raise" posture as #order_items.
        def safe_dig(hash, *keys)
          keys.reduce(hash) { |h, k| h.is_a?(Hash) ? h[k] : nil }
        end

        def order_line_item(node, status)
          quantity = node["quantity"] || 0
          fulfilled = Portage::Ucp::Support::LineItemStatus.fulfilled_quantity(status, quantity)
          unit_price = money_from_parts(safe_dig(node, "price_per_unit", "amount"), nil).amount_minor
          line_total = unit_price * quantity
          Portage::Ucp::OrderLineItem.new(
            id: node["id"].to_s,
            item: Portage::Ucp::Item.new(id: node["retailer_id"].to_s, title: node["product_name"],
                                         price: unit_price),
            quantity: { original: quantity, total: quantity, fulfilled: fulfilled },
            totals: Portage::Ucp::Support::Totals.line(line_total),
            status: status
          )
        end
      end
    end
  end
end
