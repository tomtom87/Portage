require "bigdecimal"

module Portage
  module Ucp
    module Wix
      # Converts Wix Stores/eCommerce REST response bodies into the
      # protocol-layer value objects from Portage::Ucp::ValueObjects
      # (Product/Cart/LineItem/Checkout/Order/Money) — nothing Wix-shaped is
      # allowed to leak past this file.
      #
      # Targets the Wix Stores Catalog V1 product shape (`priceData`,
      # `stock`, `productPageUrl`) rather than V3 — V1's fields are the
      # stable, longer-documented ones. A merchant on V3-only endpoints would
      # need their own Mapper.
      module Mapper
        module_function

        def money(amount, currency)
          Portage::Ucp::Money.new(amount_minor: minor_units(amount), currency: currency)
        end

        def minor_units(amount)
          return 0 unless amount

          (BigDecimal(amount.to_s) * 100).to_i
        end

        def product(node)
          currency = node.dig("priceData", "currency")
          Portage::Ucp::Product.new(
            id: node["id"],
            title: node["name"],
            description: node["description"],
            price: money(node.dig("priceData", "price"), currency),
            available: node.dig("stock", "inStock") != false,
            variants: (node["variants"] || []).map { |v| variant(v, node["name"], currency) },
            url: product_url(node["productPageUrl"])
          )
        end

        def product_url(page)
          return nil unless page && page["base"]

          "#{page['base']}#{page['path']}"
        end

        # A V1 variant's own identity is its `choices` (e.g. {"Size"=>"Large"})
        # — there's no separate variant title field, so one is built from the
        # choice values, falling back to the parent product's title for a
        # single-variant (no options) product.
        def variant(node, product_title, currency)
          choices = node["choices"] || {}
          title = choices.values.join(" / ")
          title = product_title if title.empty?
          { id: node["id"], title: title, available: node.dig("stock", "inStock") != false,
            price: money(node.dig("variant", "priceData", "price"), currency) }
        end

        def cart(node)
          Portage::Ucp::Cart.new(
            id: node["id"],
            line_items: (node["lineItems"] || []).map { |n| line_item(n) },
            currency: node["currency"],
            totals: totals(node["priceSummary"] || {})
          )
        end

        # `status` isn't reliably present on a Wix Checkout the way it is on
        # a Shopify Cart/Checkout hybrid — the adapter tracks it itself
        # across the create/update/complete/cancel lifecycle and passes it
        # in here, same rationale as Shopify's Mapper.checkout.
        def checkout(node, status:)
          Portage::Ucp::Checkout.new(
            id: node["id"],
            status: status,
            line_items: (node["lineItems"] || []).map { |n| line_item(n) },
            currency: node["currency"],
            totals: totals(node["priceSummary"] || {}),
            links: []
          )
        end

        # Shared by Cart and Checkout line items — both are Wix `lineItem`
        # shapes with the same fields. There's no documented per-line total
        # field (only a per-cart/checkout `priceSummary` aggregate), so the
        # line total is unit price * quantity, same as Shopify's variant
        # price * quantity for a line with no discounts applied.
        def line_item(node)
          unit_price = minor_units(node.dig("price", "amount"))
          quantity = node["quantity"]
          line_total = unit_price * quantity
          Portage::Ucp::LineItem.new(
            id: node["id"],
            item: Portage::Ucp::Item.new(id: node.dig("catalogReference", "catalogItemId"),
                                         title: node.dig("productName", "original"), price: unit_price),
            quantity: quantity,
            totals: [Portage::Ucp::Total.new(type: "subtotal", amount: line_total),
                     Portage::Ucp::Total.new(type: "total", amount: line_total)]
          )
        end

        # Builds the top-level totals array (exactly one subtotal + one
        # total, plus an optional tax entry) from Wix's priceSummary.
        def totals(summary)
          entries = [Portage::Ucp::Total.new(type: "subtotal", amount: minor_units(summary.dig("subtotal", "amount")))]
          tax = minor_units(summary.dig("tax", "amount"))
          entries << Portage::Ucp::Total.new(type: "tax", amount: tax) if tax.positive?
          entries << Portage::Ucp::Total.new(type: "total", amount: minor_units(summary.dig("total", "amount")))
          entries
        end

        # Wix Order line items carry their own coarse fulfillmentStatus
        # (NOT_FULFILLED/PARTIALLY_FULFILLED/FULFILLED/CANCELED) rather than
        # Shopify's separate quantity/unfulfilledQuantity counters, so exact
        # partial-fulfillment quantities aren't derivable from the Orders API
        # alone (Wix's separate Fulfillments API has those, and isn't wired
        # up here) — `fulfilled` is a best-effort all-or-nothing based on
        # that status.
        ORDER_LINE_ITEM_STATUS = {
          "FULFILLED" => "fulfilled", "CANCELED" => "removed",
          "PARTIALLY_FULFILLED" => "partial", "NOT_FULFILLED" => "processing"
        }.freeze

        # `permalink_url` is left blank — Wix's Orders API doesn't return a
        # public order-status page URL (that's rendered on the buyer's Thank
        # You page client-side, not exposed via this API).
        def order(node)
          subtotal_amount = minor_units(node.dig("priceSummary", "subtotal", "amount"))
          total_amount = minor_units(node.dig("priceSummary", "total", "amount"))
          Portage::Ucp::Order.new(
            id: node["id"],
            checkout_id: node["checkoutId"] || "",
            permalink_url: "",
            line_items: (node["lineItems"] || []).map { |n| order_line_item(n) },
            fulfillment: {},
            currency: node["currency"],
            totals: [Portage::Ucp::Total.new(type: "subtotal", amount: subtotal_amount),
                     Portage::Ucp::Total.new(type: "total", amount: total_amount)]
          )
        end

        def order_line_item(node)
          quantity = node["quantity"]
          status = ORDER_LINE_ITEM_STATUS.fetch(node["fulfillmentStatus"], "processing")
          fulfilled = status == "fulfilled" ? quantity : 0
          unit_price = minor_units(node.dig("price", "amount"))
          line_total = unit_price * quantity
          Portage::Ucp::OrderLineItem.new(
            id: node["id"],
            item: Portage::Ucp::Item.new(id: node.dig("catalogReference", "catalogItemId"),
                                         title: node.dig("productName", "original"), price: unit_price),
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
