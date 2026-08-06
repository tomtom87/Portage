require "bigdecimal"

module Portage
  module Ucp
    module WooCommerce
      # Converts WooCommerce Admin REST v3 (products, orders) and Store API
      # v1 (cart, checkout) response bodies into the protocol-layer value
      # objects from Portage::Ucp::ValueObjects — nothing WooCommerce-shaped
      # is allowed to leak past this file.
      #
      # `currency` is threaded in by the caller everywhere it's needed: the
      # Admin product resource doesn't carry a currency field at all (it's a
      # site-wide setting, not per-product), unlike the Store API's cart/
      # checkout responses, which do include one (`totals.currency_code`).
      module Mapper
        module_function

        def money(amount, currency)
          Portage::Ucp::Money.new(amount_minor: minor_units(amount), currency: currency)
        end

        def minor_units(amount)
          return 0 if amount.nil? || amount == ""

          (BigDecimal(amount.to_s) * 100).to_i
        end

        # `node["variations_detail"]` is adapter-populated, not a real WC
        # field: the Admin product resource only lists variation *ids* for a
        # variable product (`variations: [123, 124]`), so fetching full
        # variation objects is a second request the Adapter makes and merges
        # in before calling this — Mapper stays pure translation, no I/O.
        def product(node, currency:)
          Portage::Ucp::Product.new(
            id: node["id"].to_s,
            title: node["name"],
            description: node["description"],
            price: money(node["price"], currency),
            available: node["stock_status"] != "outofstock",
            variants: variants(node, currency),
            url: node["permalink"]
          )
        end

        # A simple (non-variable) product has no real variants — it's its
        # own single implicit variant, same as a single-variant Shopify
        # product using that variant's own id.
        def variants(node, currency)
          detail = node["variations_detail"]
          unless detail
            return [{ id: node["id"].to_s, title: node["name"],
                      available: node["stock_status"] != "outofstock", price: money(node["price"], currency) }]
          end

          detail.map { |v| variant(v, currency) }
        end

        def variant(node, currency)
          title = (node["attributes"] || []).map { |a| a["option"] }.join(" / ")
          { id: node["id"].to_s, title: title, available: node["stock_status"] != "outofstock",
            price: money(node["price"], currency) }
        end

        # `id:` is caller-supplied rather than read off the response body:
        # the Store API cart has no in-body resource id, only a `cart_hash`
        # change-detection fingerprint. What actually identifies "this cart"
        # across calls is the opaque `Cart-Token` the session is keyed by
        # (see Portage::Ucp::WooCommerce::Client) — the Adapter passes that
        # token through as `id:`.
        def cart(node, id:)
          currency = node.dig("totals", "currency_code")
          Portage::Ucp::Cart.new(
            id: id,
            line_items: (node["items"] || []).map { |n| cart_line_item(n, currency) },
            currency: currency,
            totals: totals(node["totals"] || {})
          )
        end

        # `status` isn't a Store API cart field either — the Store API's
        # cart *is* the checkout, same as Shopify's Cart-as-Checkout, so the
        # adapter tracks status itself and passes it in here, same rationale
        # as `id:` above.
        def checkout(node, id:, status:, order: nil)
          currency = node.dig("totals", "currency_code")
          Portage::Ucp::Checkout.new(
            id: id,
            status: status,
            line_items: (node["items"] || []).map { |n| cart_line_item(n, currency) },
            currency: currency,
            totals: totals(node["totals"] || {}),
            links: [],
            order: order
          )
        end

        def cart_line_item(node, _currency)
          unit_price = minor_units_from_subunits(node.dig("prices", "price"), node.dig("prices", "currency_minor_unit"))
          line_total = unit_price * node["quantity"]
          Portage::Ucp::LineItem.new(
            id: node["key"],
            item: Portage::Ucp::Item.new(id: node["id"].to_s, title: node["name"], price: unit_price,
                                         image_url: node.dig("images", 0, "thumbnail")),
            quantity: node["quantity"],
            totals: [Portage::Ucp::Total.new(type: "subtotal", amount: line_total),
                     Portage::Ucp::Total.new(type: "total", amount: line_total)]
          )
        end

        # Store API money fields are already minor-unit integers as strings
        # (e.g. "500" for $5.00), tagged with `currency_minor_unit` (usually
        # 2) — unlike the Admin API's decimal strings, there's no BigDecimal
        # conversion needed here, just an integer parse.
        def minor_units_from_subunits(amount, _minor_unit)
          return 0 if amount.nil?

          amount.to_i
        end

        def totals(node)
          entries = [Portage::Ucp::Total.new(type: "subtotal",
                                             amount: minor_units_from_subunits(
                                               node["total_items"], nil
                                             ))]
          tax = minor_units_from_subunits(node["total_tax"], nil)
          entries << Portage::Ucp::Total.new(type: "tax", amount: tax) if tax.positive?
          entries << Portage::Ucp::Total.new(type: "total", amount: minor_units_from_subunits(node["total_price"], nil))
          entries
        end

        # WooCommerce core has no per-line-item fulfillment tracking (that's
        # a shipment-tracking-plugin concern) — every line is given the same
        # coarse status derived from the order's own top-level `status`,
        # rather than a real per-line signal.
        ORDER_LINE_ITEM_STATUS = {
          "completed" => "fulfilled", "processing" => "processing", "pending" => "processing",
          "on-hold" => "processing", "cancelled" => "removed", "refunded" => "removed", "failed" => "removed"
        }.freeze

        # `permalink_url` is built from WooCommerce's documented order-
        # received URL pattern (`/checkout/order-received/{id}/?key={key}`)
        # — the Admin order resource doesn't return a ready-made link the
        # way Shopify's `statusPageUrl` does. `checkout_id` isn't a WC order
        # field at all — nothing on Order links back to the Cart-Token that
        # produced it, so the Adapter resolves it itself (tracked in-process
        # from the #complete_checkout call that created the order, since the
        # Store API's checkout response hands back the new order id right
        # then) and passes it in here, same as Shopify's Mapper.order.
        def order(node, site_url:, checkout_id: "")
          currency = node["currency"]
          subtotal = minor_units(node["total"]) - minor_units(node["total_tax"])
          status = ORDER_LINE_ITEM_STATUS.fetch(node["status"], "processing")
          Portage::Ucp::Order.new(
            id: node["id"].to_s,
            checkout_id: checkout_id,
            permalink_url: "#{site_url}/checkout/order-received/#{node['id']}/?key=#{node['order_key']}",
            line_items: (node["line_items"] || []).map { |n| order_line_item(n, currency, status) },
            fulfillment: Portage::Ucp::Fulfillment.new,
            currency: currency,
            totals: [Portage::Ucp::Total.new(type: "subtotal", amount: subtotal),
                     Portage::Ucp::Total.new(type: "total", amount: minor_units(node["total"]))]
          )
        end

        def order_line_item(node, currency, status)
          quantity = node["quantity"]
          fulfilled = status == "fulfilled" ? quantity : 0
          line_total = minor_units(node["total"])
          Portage::Ucp::OrderLineItem.new(
            id: node["id"].to_s,
            item: Portage::Ucp::Item.new(id: (node["variation_id"] || node["product_id"]).to_s, title: node["name"],
                                         price: money(node["price"], currency).amount_minor),
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
