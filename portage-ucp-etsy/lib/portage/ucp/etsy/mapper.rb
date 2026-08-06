module Portage
  module Ucp
    module Etsy
      # Converts Etsy Open API v3 response bodies into the protocol-layer
      # value objects from Portage::Ucp::ValueObjects — nothing Etsy-shaped
      # is allowed to leak past this file.
      #
      # Etsy's `Money` type (`{amount, divisor, currency_code}`) is already
      # an integer, unlike every other adapter in this project — `amount /
      # divisor` gives the decimal value, but `amount` itself is already in
      # the currency's minor units when `divisor` is 100 (the only value
      # Etsy documents ever returning), so no BigDecimal conversion is
      # needed here at all.
      module Mapper
        module_function

        def money(node)
          Portage::Ucp::Money.new(amount_minor: node["amount"], currency: node["currency_code"])
        end

        # `node["variants_detail"]` is adapter-populated, not a real Etsy
        # field: a listing's own resource has no variant/SKU breakdown at
        # all — that's a second call to the separate Inventory endpoint
        # (`/listings/{id}/inventory`), made only for #get_product's
        # single-listing path, same reasoning as every other adapter's N+1
        # variant fetch.
        def product(node)
          Portage::Ucp::Product.new(
            id: node["listing_id"].to_s,
            title: node["title"],
            description: node["description"],
            price: money(node["price"]),
            available: node["state"] == "active" && node["quantity"].to_i.positive?,
            variants: variants(node),
            url: node["url"]
          )
        end

        # A listing with no inventory-level variation is its own single
        # implicit variant, same as a single-variant Shopify product using
        # that variant's own id.
        def variants(node)
          detail = node["variants_detail"]
          unless detail
            return [{ id: node["listing_id"].to_s, title: node["title"],
                      available: node["state"] == "active" && node["quantity"].to_i.positive?,
                      price: money(node["price"]) }]
          end

          (detail["products"] || []).reject { |p| p["is_deleted"] }.map { |p| variant(p) }
        end

        def variant(node)
          title = (node["property_values"] || []).flat_map { |p| p["values"] }.join(" / ")
          offering = (node["offerings"] || []).find { |o| o["is_enabled"] } || {}
          { id: node["product_id"].to_s, title: title, available: offering["quantity"].to_i.positive?,
            price: money(offering["price"] || {}) }
        end

        # `id:` is caller-supplied: there's no real Etsy checkout resource
        # behind this at all — see Portage::Ucp::Etsy::Adapter's class-level
        # comment. `links` points at each listing's own public Etsy URL
        # rather than a cart, since Etsy's public API has no way to deep-
        # link a multi-item add-to-cart flow.
        def checkout(listings, id:, status:)
          line_items = listings.map { |l| checkout_line_item(l) }
          currency = listings.first&.dig("price", "currency_code")
          Portage::Ucp::Checkout.new(
            id: id,
            status: status,
            line_items: line_items,
            currency: currency,
            totals: totals(listings),
            links: listings.map { |l| Portage::Ucp::Link.new(type: "checkout", url: l["url"], title: l["title"]) }
          )
        end

        def checkout_line_item(node)
          Portage::Ucp::LineItem.new(
            id: node["listing_id"].to_s,
            item: Portage::Ucp::Item.new(id: node["listing_id"].to_s, title: node["title"],
                                         price: node.dig("price", "amount")),
            quantity: node["quantity"] || 1,
            totals: [Portage::Ucp::Total.new(type: "subtotal", amount: line_total(node)),
                     Portage::Ucp::Total.new(type: "total", amount: line_total(node))]
          )
        end

        def line_total(node)
          node.dig("price", "amount") * (node["quantity"] || 1)
        end

        def totals(listings)
          subtotal = listings.sum { |l| line_total(l) }
          [Portage::Ucp::Total.new(type: "subtotal", amount: subtotal),
           Portage::Ucp::Total.new(type: "total", amount: subtotal)]
        end

        # Etsy core has no per-transaction fulfillment tracking on the
        # Receipt resource beyond a single receipt-wide `is_shipped` flag —
        # every line gets the same coarse status, same simplification as
        # Portage::Ucp::WooCommerce::Mapper/Portage::Ucp::Magento::Mapper.
        #
        # `permalink_url` is left blank — Etsy's API doesn't return a
        # public, shareable receipt URL (buyers see receipts inside their
        # own account, not via a link). `checkout_id` is always blank too,
        # for a more fundamental reason than the other adapters: this
        # gem's Checkout is never a real Etsy resource (see
        # Portage::Ucp::Etsy::Adapter), so there is no "checkout that led
        # to this receipt" for the adapter to have recorded in the first
        # place.
        def receipt_status(node)
          return "fulfilled" if node["is_shipped"]
          return "removed" if node["status"] == "canceled"

          "processing"
        end

        def order(node)
          status = receipt_status(node)
          Portage::Ucp::Order.new(
            id: node["receipt_id"].to_s,
            checkout_id: "",
            permalink_url: "",
            line_items: (node["transactions"] || []).map { |n| order_line_item(n, status) },
            fulfillment: Portage::Ucp::Fulfillment.new,
            currency: node.dig("total_price", "currency_code"),
            totals: [Portage::Ucp::Total.new(type: "subtotal", amount: money(node["subtotal"]).amount_minor),
                     Portage::Ucp::Total.new(type: "total", amount: money(node["total_price"]).amount_minor)]
          )
        end

        def order_line_item(node, status)
          quantity = node["quantity"]
          fulfilled = status == "fulfilled" ? quantity : 0
          line_total = node.dig("price", "amount") * quantity
          Portage::Ucp::OrderLineItem.new(
            id: node["transaction_id"].to_s,
            item: Portage::Ucp::Item.new(id: node["listing_id"].to_s, title: node["title"],
                                         price: node.dig("price", "amount")),
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
