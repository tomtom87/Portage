require "bigdecimal"

module Portage
  module Ucp
    module Magento
      # Converts Magento REST v1 response bodies into the protocol-layer
      # value objects from Portage::Ucp::ValueObjects — nothing Magento-
      # shaped is allowed to leak past this file.
      #
      # `currency` is threaded in by the caller everywhere it's needed: the
      # product resource has no currency field (a site-wide/store-view
      # setting, not per-product), same limitation as WooCommerce's Admin
      # product resource.
      #
      # Cart items are identified by `sku`, not a numeric id — Magento's
      # `cartItem` add/update payloads take `sku`, so that's what's threaded
      # through as UCP's `product_id` everywhere in this gem, not the
      # product's numeric `id`.
      module Mapper
        module_function

        def money(amount, currency)
          Portage::Ucp::Money.new(amount_minor: minor_units(amount), currency: currency)
        end

        def minor_units(amount)
          return 0 if amount.nil?

          (BigDecimal(amount.to_s) * 100).to_i
        end

        def custom_attribute(node, code)
          (node["custom_attributes"] || []).find { |a| a["attribute_code"] == code }&.dig("value")
        end

        def in_stock?(node)
          node.dig("extension_attributes", "stock_item", "is_in_stock") != false
        end

        # `node["children_detail"]` is adapter-populated, not a real Magento
        # field: a configurable product's own resource only lists child skus
        # under `extension_attributes.configurable_product_links` (bare ids)
        # — fetching the full child product objects
        # (`/configurable-products/{sku}/children`) is a second request the
        # Adapter makes and merges in before calling this, same reasoning as
        # Portage::Ucp::WooCommerce::Mapper's `variations_detail`.
        def product(node, currency:, site_url: nil)
          Portage::Ucp::Product.new(
            id: node["sku"],
            title: node["name"],
            description: custom_attribute(node, "description"),
            price: money(node["price"], currency),
            available: node["status"] == 1 && in_stock?(node),
            variants: variants(node, currency),
            url: product_url(node, site_url)
          )
        end

        def product_url(node, site_url)
          url_key = custom_attribute(node, "url_key")
          return nil unless site_url && url_key

          "#{site_url}/#{url_key}.html"
        end

        # A simple product has no real variants — it's its own single
        # implicit variant, same as a single-variant Shopify product using
        # that variant's own id.
        def variants(node, currency)
          children = node["children_detail"]
          unless children
            return [{ id: node["sku"], title: node["name"], available: node["status"] == 1 && in_stock?(node),
                      price: money(node["price"], currency) }]
          end

          children.map do |c|
            { id: c["sku"], title: c["name"], available: c["status"] == 1 && in_stock?(c),
              price: money(c["price"], currency) }
          end
        end

        # `id:` and `currency:` are caller-supplied: the guest-cart `items`
        # resource (sku/name/qty/price) and `totals` resource (row totals,
        # tax, `quote_currency_code`) are two separate Magento REST calls —
        # the Adapter merges them by `item_id` before calling this, same
        # reasoning as Portage::Ucp::WooCommerce::Mapper needing `id:`
        # supplied (Magento's cart has no single resource id of its own
        # either, just the masked cart id used in the URL).
        def cart(items, id:, currency:)
          Portage::Ucp::Cart.new(
            id: id,
            line_items: items.map { |n| cart_line_item(n) },
            currency: currency,
            totals: totals(items)
          )
        end

        # `status` isn't a Magento cart field — a Magento guest cart *is*
        # the checkout (there's no separate Checkout resource, only the
        # shipping-information/payment-information calls that act on the
        # same cart), so the Adapter tracks status itself and passes it in
        # here, same rationale as Shopify's Cart-as-Checkout.
        def checkout(items, id:, currency:, status:)
          Portage::Ucp::Checkout.new(
            id: id,
            status: status,
            line_items: items.map { |n| cart_line_item(n) },
            currency: currency,
            totals: totals(items),
            links: []
          )
        end

        def cart_line_item(node)
          line_total = minor_units(node["row_total"])
          quantity = node["qty"]
          unit_price = quantity.to_i.positive? ? (line_total / quantity).round : minor_units(node["price"])
          Portage::Ucp::LineItem.new(
            id: node["item_id"].to_s,
            item: Portage::Ucp::Item.new(id: node["sku"], title: node["name"], price: unit_price),
            quantity: quantity,
            totals: [Portage::Ucp::Total.new(type: "subtotal", amount: line_total),
                     Portage::Ucp::Total.new(type: "total", amount: line_total)]
          )
        end

        # Builds the top-level totals array from the merged line items'
        # row_total (subtotal) plus each line's own tax_amount, since
        # there's no single caller-supplied totals hash here the way
        # Shopify/Wix/WooCommerce have one — see #cart's comment on why
        # items/totals are merged per-line before reaching this module.
        def totals(items)
          subtotal = items.sum { |n| minor_units(n["row_total"]) }
          tax = items.sum { |n| minor_units(n["tax_amount"]) }
          entries = [Portage::Ucp::Total.new(type: "subtotal", amount: subtotal)]
          entries << Portage::Ucp::Total.new(type: "tax", amount: tax) if tax.positive?
          entries << Portage::Ucp::Total.new(type: "total", amount: subtotal + tax)
          entries
        end

        # Magento core has no per-line-item fulfillment tracking on the
        # Order resource itself (that's the separate Shipments API) — every
        # line is given the same coarse status derived from the order's own
        # top-level `status`, same simplification as
        # Portage::Ucp::WooCommerce::Mapper.
        ORDER_LINE_ITEM_STATUS = {
          "complete" => "fulfilled", "closed" => "fulfilled", "processing" => "processing",
          "pending" => "processing", "canceled" => "removed"
        }.freeze

        # `permalink_url` is left blank — Magento's Orders API doesn't
        # return a public order-status page URL (guest order tracking is a
        # storefront form, not a direct link). `checkout_id` isn't a
        # reachable Magento order field either: `order.quote_id` is the
        # cart's *internal* integer id, not the masked guest-cart id used in
        # every REST URL, and Magento doesn't expose the mapping between the
        # two via the API — so, like WooCommerce, the Adapter records it
        # itself at #complete_checkout time instead.
        def order(node, checkout_id: "")
          currency = node["order_currency_code"]
          subtotal = minor_units(node["subtotal"])
          total = minor_units(node["grand_total"])
          status = ORDER_LINE_ITEM_STATUS.fetch(node["status"], "processing")
          Portage::Ucp::Order.new(
            id: node["entity_id"].to_s,
            checkout_id: checkout_id,
            permalink_url: "",
            line_items: (node["items"] || []).map { |n| order_line_item(n, status) },
            fulfillment: {},
            currency: currency,
            totals: [Portage::Ucp::Total.new(type: "subtotal", amount: subtotal),
                     Portage::Ucp::Total.new(type: "total", amount: total)]
          )
        end

        def order_line_item(node, status)
          quantity = node["qty_ordered"].to_i
          fulfilled = status == "fulfilled" ? quantity : 0
          line_total = minor_units(node["row_total"])
          Portage::Ucp::OrderLineItem.new(
            id: node["item_id"].to_s,
            item: Portage::Ucp::Item.new(id: node["sku"], title: node["name"], price: minor_units(node["price"])),
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
