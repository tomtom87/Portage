require "spec_helper"

RSpec.describe Portage::Ucp::Shopify::Mapper do
  describe ".money" do
    it "converts a decimal amount string to integer minor units without float drift" do
      money = described_class.money({ "amount" => "19.99", "currencyCode" => "USD" })

      expect(money).to eq(Portage::Ucp::Money.new(amount_minor: 1999, currency: "USD"))
    end
  end

  describe ".product" do
    let(:node) do
      {
        "id" => "gid://shopify/Product/1", "handle" => "cold-brew", "title" => "Cold Brew", "description" => "desc",
        "descriptionHtml" => "<p>desc</p>",
        "onlineStoreUrl" => "https://test-shop.myshopify.com/products/cold-brew",
        "tags" => ["coffee"],
        "priceRange" => { "minVariantPrice" => { "amount" => "5.00", "currencyCode" => "USD" },
                          "maxVariantPrice" => { "amount" => "5.00", "currencyCode" => "USD" } },
        "compareAtPriceRange" => nil,
        "featuredMedia" => { "nodes" => [{ "image" => { "url" => "https://cdn.example/1.jpg", "altText" => "Cold Brew",
                                                        "width" => 800, "height" => 800 } }] },
        "options" => [{ "name" => "Size", "optionValues" => [{ "id" => "opt_1", "name" => "12oz" }] }],
        "variants" => { "nodes" => [
          { "id" => "gid://shopify/ProductVariant/1", "title" => "Default", "availableForSale" => true,
            "sku" => "CB-12", "barcode" => "012345678905",
            "price" => "5.00", "compareAtPrice" => nil,
            "selectedOptions" => [{ "name" => "Size", "value" => "12oz" }], "image" => nil }
        ] }
      }
    end

    it "maps a Shopify product node to a Portage::Ucp::Product" do
      product = described_class.product(node)

      expect(product.id).to eq("gid://shopify/Product/1")
      expect(product.price_range).to eq(
        Portage::Ucp::PriceRange.new(min: Portage::Ucp::Price.new(amount: 500, currency: "USD"),
                                     max: Portage::Ucp::Price.new(amount: 500, currency: "USD"))
      )
      expect(product.variants.size).to eq(1)

      variant = product.variants.first
      expect(variant.id).to eq("gid://shopify/ProductVariant/1")
      expect(variant.sku).to eq("CB-12")
      expect(variant.price).to eq(Portage::Ucp::Price.new(amount: 500, currency: "USD"))
      expect(variant.availability).to eq({ "available" => true })
    end

    it "maps a UPC-length barcode to a UPC-tagged GTIN" do
      variant = described_class.product(node).variants.first
      expect(variant.barcodes).to eq([{ "type" => "UPC", "value" => "012345678905" }])
    end

    it "maps structured options through onto both Product and Variant" do
      product = described_class.product(node)

      expect(product.options.map(&:to_wire_h)).to eq(
        [{ "name" => "Size", "values" => [{ "id" => "opt_1", "label" => "12oz" }] }]
      )
      expect(product.variants.first.options.map(&:to_wire_h)).to eq([{ "name" => "Size", "label" => "12oz" }])
    end
  end

  describe ".cart / .checkout" do
    let(:node) do
      {
        "id" => "gid://shopify/Cart/1",
        "cost" => { "subtotalAmount" => { "amount" => "10.00", "currencyCode" => "USD" },
                    "totalTaxAmount" => { "amount" => "1.00", "currencyCode" => "USD" },
                    "totalAmount" => { "amount" => "11.00", "currencyCode" => "USD" } },
        "lines" => { "nodes" => [
          { "id" => "gid://shopify/CartLine/1", "quantity" => 2,
            "cost" => { "totalAmount" => { "amount" => "10.00", "currencyCode" => "USD" } },
            "merchandise" => { "id" => "gid://shopify/ProductVariant/1", "product" => { "title" => "Cold Brew" },
                               "price" => { "amount" => "5.00", "currencyCode" => "USD" } } }
        ] }
      }
    end

    it "maps a Shopify cart node to a Portage::Ucp::Cart with its line items and totals array" do
      cart = described_class.cart(node)

      expect(cart.id).to eq("gid://shopify/Cart/1")
      expect(cart.totals).to eq([
                                  Portage::Ucp::Total.new(type: "subtotal", amount: 1000),
                                  Portage::Ucp::Total.new(type: "tax", amount: 100),
                                  Portage::Ucp::Total.new(type: "total", amount: 1100)
                                ])
      expect(cart.line_items).to eq([
                                      Portage::Ucp::LineItem.new(
                                        id: "gid://shopify/CartLine/1",
                                        item: Portage::Ucp::Item.new(id: "gid://shopify/ProductVariant/1",
                                                                     title: "Cold Brew", price: 500),
                                        quantity: 2,
                                        totals: [Portage::Ucp::Total.new(type: "subtotal", amount: 1000),
                                                 Portage::Ucp::Total.new(type: "total", amount: 1000)]
                                      )
                                    ])
    end

    it "treats a null totalTaxAmount (tax not yet computed) as zero rather than raising" do
      untaxed_node = node.merge("cost" => node["cost"].merge("totalTaxAmount" => nil))

      cart = described_class.cart(untaxed_node)

      expect(cart.totals.map(&:type)).not_to include("tax")
    end

    it "sets Checkout status from the caller rather than any Shopify field, and includes required links" do
      checkout = described_class.checkout(node, status: "completed")

      expect(checkout.status).to eq("completed")
      expect(checkout.links).to eq([])
      expect(checkout.totals.find { |t| t.type == "total" }.amount).to eq(1100)
    end

    it "maps discountCodes/discountAllocations into a Portage::Ucp::Discounts" do
      with_discounts = node.merge(
        "discountCodes" => [{ "code" => "SAVE10", "applicable" => true }],
        "discountAllocations" => [
          { "code" => "SAVE10", "discountedAmount" => { "amount" => "1.00", "currencyCode" => "USD" } }
        ]
      )

      cart = described_class.cart(with_discounts)

      expect(cart.discounts.codes).to eq(["SAVE10"])
      expect(cart.discounts.applied).to eq([
                                             Portage::Ucp::AppliedDiscount.new(title: "SAVE10", amount: 100,
                                                                               code: "SAVE10", automatic: false)
                                           ])
    end

    it "treats an allocation with no code as automatic, titled from Shopify's title field" do
      with_discounts = node.merge(
        "discountAllocations" => [
          { "title" => "Free Shipping", "discountedAmount" => { "amount" => "5.00", "currencyCode" => "USD" } }
        ]
      )

      cart = described_class.cart(with_discounts)

      expect(cart.discounts.applied.first.automatic).to eq(true)
      expect(cart.discounts.applied.first.title).to eq("Free Shipping")
    end

    it "omits discounts from the wire shape when the cart has no codes or allocations" do
      cart = described_class.cart(node)
      expect(cart.to_wire_h).not_to have_key("discounts")
    end

    it "omits fulfillment when the cart has no deliveryGroups" do
      checkout = described_class.checkout(node, status: "incomplete")

      expect(checkout.to_wire_h).not_to have_key("fulfillment")
    end
  end

  describe ".checkout_fulfillment" do
    let(:node) do
      {
        "id" => "gid://shopify/Cart/1",
        "deliveryGroups" => { "nodes" => [
          { "id" => "gid://shopify/CartDeliveryGroup/1",
            "cartLines" => { "nodes" => [{ "id" => "gid://shopify/CartLine/1" }] },
            "deliveryOptions" => [
              { "handle" => "standard", "title" => "Standard Shipping", "description" => "5-7 days",
                "deliveryMethodType" => "SHIPPING",
                "estimatedCost" => { "amount" => "5.00", "currencyCode" => "USD" } },
              { "handle" => "express", "title" => "Express", "description" => "1-2 days",
                "deliveryMethodType" => "SHIPPING",
                "estimatedCost" => { "amount" => "15.00", "currencyCode" => "USD" } }
            ],
            "selectedDeliveryOption" => { "handle" => "standard" },
            "deliveryAddress" => { "address1" => "1 Main St", "address2" => nil, "city" => "Erie",
                                   "provinceCode" => "PA", "zip" => "16501", "firstName" => "A", "lastName" => "B",
                                   "phone" => nil, "countryCode" => "US" } }
        ] }
      }
    end

    it "collapses Shopify's deliveryGroups into a single synthesized shipping method" do
      fulfillment = described_class.checkout_fulfillment(node)

      expect(fulfillment.shipping_methods.size).to eq(1)
      method = fulfillment.shipping_methods.first
      expect(method.type).to eq("shipping")
      expect(method.line_item_ids).to eq(["gid://shopify/CartLine/1"])
    end

    it "maps each Shopify deliveryGroup to a FulfillmentGroup with its priced options" do
      group = described_class.checkout_fulfillment(node).shipping_methods.first.groups.first

      expect(group.id).to eq("gid://shopify/CartDeliveryGroup/1")
      expect(group.selected_option_id).to eq("standard")
      expect(group.options.map(&:id)).to eq(%w[standard express])
      expect(group.options.first.totals).to eq([Portage::Ucp::Total.new(type: "total", amount: 500)])
    end

    it "exposes the cart's one buyer-submitted address as the single destination \"current\"" do
      method = described_class.checkout_fulfillment(node).shipping_methods.first

      expect(method.selected_destination_id).to eq("current")
      expect(method.destinations.first.address.address_locality).to eq("Erie")
    end

    it "is empty when the cart has no deliveryGroups" do
      expect(described_class.checkout_fulfillment("id" => "gid://shopify/Cart/1")).to be_empty
    end
  end

  describe ".order" do
    let(:node) do
      {
        "id" => "gid://shopify/Order/1", "statusPageUrl" => "https://ucp-test.myshopify.com/orders/abc123",
        "currentTotalPriceSet" => { "shopMoney" => { "amount" => "11.00", "currencyCode" => "USD" } },
        "currentSubtotalPriceSet" => { "shopMoney" => { "amount" => "10.00", "currencyCode" => "USD" } },
        "lineItems" => { "nodes" => [
          { "id" => "gid://shopify/LineItem/1", "quantity" => 2, "currentQuantity" => 2, "unfulfilledQuantity" => 0,
            "discountedTotalSet" => { "shopMoney" => { "amount" => "10.00", "currencyCode" => "USD" } },
            "variant" => { "id" => "gid://shopify/ProductVariant/1", "title" => "Default",
                           "price" => { "amount" => "5.00", "currencyCode" => "USD" } } }
        ] }
      }
    end

    it "maps a Shopify order node to an Order, defaulting checkout_id when the caller doesn't supply one" do
      order = described_class.order(node)

      expect(order.id).to eq("gid://shopify/Order/1")
      expect(order.checkout_id).to eq("")
      expect(order.permalink_url).to eq("https://ucp-test.myshopify.com/orders/abc123")
      expect(order.fulfillment).to eq(Portage::Ucp::Fulfillment.new)
      expect(order.totals).to eq([Portage::Ucp::Total.new(type: "subtotal", amount: 1000),
                                  Portage::Ucp::Total.new(type: "total", amount: 1100)])
      expect(order.line_items.first.quantity).to eq({ original: 2, total: 2, fulfilled: 2 })
      expect(order.line_items.first.status).to eq("fulfilled")
    end

    it "threads a caller-supplied checkout_id through, the same way #checkout's status is caller-supplied" do
      order = described_class.order(node, checkout_id: "gid://shopify/Cart/1")

      expect(order.checkout_id).to eq("gid://shopify/Cart/1")
    end

    it "derives partial/processing/removed line item status from quantity tracking" do
      shared = { "discountedTotalSet" => { "shopMoney" => { "amount" => "10.00", "currencyCode" => "USD" } },
                 "variant" => nil }
      partial = described_class.order_line_item(
        shared.merge("id" => "li_1", "quantity" => 3, "currentQuantity" => 3, "unfulfilledQuantity" => 1)
      )
      processing = described_class.order_line_item(
        shared.merge("id" => "li_2", "quantity" => 3, "currentQuantity" => 3, "unfulfilledQuantity" => 3)
      )
      removed = described_class.order_line_item(
        shared.merge("id" => "li_3", "quantity" => 3, "currentQuantity" => 0, "unfulfilledQuantity" => 0,
                     "discountedTotalSet" => { "shopMoney" => { "amount" => "0.00", "currencyCode" => "USD" } })
      )

      expect(partial.status).to eq("partial")
      expect(processing.status).to eq("processing")
      expect(removed.status).to eq("removed")
    end

    it "maps cancellation/refund/return data into adjustments (§16)" do
      with_adjustments = node.merge(
        "cancelledAt" => "2026-08-20T12:00:00Z", "cancelReason" => "CUSTOMER",
        "refunds" => [
          { "id" => "gid://shopify/Refund/1", "createdAt" => "2026-08-19T00:00:00Z", "note" => "damaged",
            "totalRefundedSet" => { "shopMoney" => { "amount" => "5.00", "currencyCode" => "USD" } },
            "refundLineItems" => { "nodes" => [
              { "quantity" => 1, "lineItem" => { "id" => "gid://shopify/LineItem/1" } }
            ] } }
        ],
        "returns" => { "nodes" => [
          { "id" => "gid://shopify/Return/1", "status" => "OPEN", "requestedAt" => "2026-08-18T00:00:00Z",
            "returnLineItems" => { "nodes" => [
              { "quantity" => 1, "returnReasonNote" => "wrong size",
                "fulfillmentLineItem" => { "lineItem" => { "id" => "gid://shopify/LineItem/1" } } }
            ] } }
        ] }
      )

      order = described_class.order(with_adjustments)
      cancellation, refund, ret = order.adjustments

      expect(cancellation.type).to eq("cancellation")
      expect(cancellation.status).to eq("completed")
      expect(cancellation.description).to eq("CUSTOMER")

      expect(refund.type).to eq("refund")
      expect(refund.status).to eq("completed")
      expect(refund.line_items).to eq([{ "id" => "gid://shopify/LineItem/1", "quantity" => -1 }])
      expect(refund.totals).to eq([Portage::Ucp::Total.new(type: "total", amount: -500)])
      expect(refund.description).to eq("damaged")

      expect(ret.type).to eq("return")
      expect(ret.status).to eq("pending")
      expect(ret.line_items).to eq([{ "id" => "gid://shopify/LineItem/1", "quantity" => -1 }])
      expect(ret.description).to eq("wrong size")
    end

    it "omits adjustments entirely for an order with no cancellation/refund/return activity" do
      expect(described_class.order(node).adjustments).to eq([])
    end
  end

  describe ".fulfillment" do
    let(:node) do
      {
        "fulfillmentOrders" => { "nodes" => [
          { "id" => "gid://shopify/FulfillmentOrder/1", "fulfillAt" => "2026-07-25T00:00:00Z",
            "deliveryMethod" => { "methodType" => "SHIPPING" },
            "destination" => { "address1" => "1 Main St", "address2" => nil, "city" => "Boston",
                               "province" => "MA", "zip" => "02110", "countryCode" => "US",
                               "firstName" => "Ada", "lastName" => "Lovelace", "phone" => nil },
            "lineItems" => { "nodes" => [
              { "totalQuantity" => 2, "lineItem" => { "id" => "gid://shopify/LineItem/1" } }
            ] } }
        ] },
        "fulfillments" => [
          { "id" => "gid://shopify/Fulfillment/1", "displayStatus" => "IN_TRANSIT",
            "createdAt" => "2026-07-26T00:00:00Z",
            "trackingInfo" => [{ "company" => "UPS", "number" => "1Z999", "url" => "https://ups.example/1Z999" }],
            "fulfillmentLineItems" => { "nodes" => [
              { "quantity" => 2, "lineItem" => { "id" => "gid://shopify/LineItem/1" } },
              { "quantity" => 0, "lineItem" => { "id" => "gid://shopify/LineItem/2" } }
            ] } }
        ]
      }
    end

    it "maps fulfillmentOrders to expectations with destination and method_type" do
      fulfillment = described_class.fulfillment(node)

      expect(fulfillment.expectations.map(&:to_wire_h)).to eq([
                                                                { "id" => "gid://shopify/FulfillmentOrder/1",
                                                                  "line_items" => [{ "id" => "gid://shopify/LineItem/1",
                                                                                     "quantity" => 2 }],
                                                                  "method_type" => "shipping",
                                                                  "destination" => { "street_address" => "1 Main St",
                                                                                     "address_locality" => "Boston",
                                                                                     "address_region" => "MA",
                                                                                     "address_country" => "US",
                                                                                     "postal_code" => "02110",
                                                                                     "first_name" => "Ada",
                                                                                     "last_name" => "Lovelace" },
                                                                  "fulfillable_on" => "2026-07-25T00:00:00Z" }
                                                              ])
    end

    it "maps fulfillments to events with tracking info, dropping zero-quantity line item refs" do
      fulfillment = described_class.fulfillment(node)

      expect(fulfillment.events.map(&:to_wire_h)).to eq([
                                                          { "id" => "gid://shopify/Fulfillment/1",
                                                            "occurred_at" => "2026-07-26T00:00:00Z",
                                                            "type" => "in_transit",
                                                            "line_items" => [{ "id" => "gid://shopify/LineItem/1",
                                                                               "quantity" => 2 }],
                                                            "tracking_number" => "1Z999",
                                                            "tracking_url" => "https://ups.example/1Z999",
                                                            "carrier" => "UPS" }
                                                        ])
    end

    it "defaults to empty expectations/events when the order has no fulfillment data" do
      expect(described_class.fulfillment({}).to_wire_h).to eq({ "expectations" => [], "events" => [] })
    end
  end
end
