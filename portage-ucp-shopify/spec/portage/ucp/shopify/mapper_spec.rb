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
        "id" => "gid://shopify/Product/1", "title" => "Cold Brew", "description" => "desc",
        "onlineStoreUrl" => "https://test-shop.myshopify.com/products/cold-brew",
        "availableForSale" => true,
        "priceRange" => { "minVariantPrice" => { "amount" => "5.00", "currencyCode" => "USD" } },
        "variants" => { "nodes" => [
          { "id" => "gid://shopify/ProductVariant/1", "title" => "Default", "availableForSale" => true,
            "price" => { "amount" => "5.00", "currencyCode" => "USD" } }
        ] }
      }
    end

    it "maps a Shopify product node to a Portage::Ucp::Product" do
      product = described_class.product(node)

      expect(product.id).to eq("gid://shopify/Product/1")
      expect(product.price).to eq(Portage::Ucp::Money.new(amount_minor: 500, currency: "USD"))
      expect(product.variants).to eq([{ id: "gid://shopify/ProductVariant/1", title: "Default", available: true,
                                        price: Portage::Ucp::Money.new(amount_minor: 500, currency: "USD") }])
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

    it "sets Checkout status from the caller rather than any Shopify field, and includes required links" do
      checkout = described_class.checkout(node, status: "completed")

      expect(checkout.status).to eq("completed")
      expect(checkout.links).to eq([])
      expect(checkout.totals.find { |t| t.type == "total" }.amount).to eq(1100)
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
      expect(order.fulfillment).to eq({ "expectations" => [], "events" => [] })
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

      expect(fulfillment["expectations"]).to eq([
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

      expect(fulfillment["events"]).to eq([
                                            { "id" => "gid://shopify/Fulfillment/1",
                                              "occurred_at" => "2026-07-26T00:00:00Z", "type" => "in_transit",
                                              "line_items" => [{ "id" => "gid://shopify/LineItem/1",
                                                                 "quantity" => 2 }],
                                              "tracking_number" => "1Z999",
                                              "tracking_url" => "https://ups.example/1Z999", "carrier" => "UPS" }
                                          ])
    end

    it "defaults to empty expectations/events when the order has no fulfillment data" do
      expect(described_class.fulfillment({})).to eq({ "expectations" => [], "events" => [] })
    end
  end
end
