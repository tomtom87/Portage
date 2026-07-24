require "spec_helper"

RSpec.describe UcpMcp::Shopify::Mapper do
  describe ".money" do
    it "converts a decimal amount string to integer minor units without float drift" do
      money = described_class.money({ "amount" => "19.99", "currencyCode" => "USD" })

      expect(money).to eq(UcpMcp::Money.new(amount_minor: 1999, currency: "USD"))
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

    it "maps a Shopify product node to a UcpMcp::Product" do
      product = described_class.product(node)

      expect(product.id).to eq("gid://shopify/Product/1")
      expect(product.price).to eq(UcpMcp::Money.new(amount_minor: 500, currency: "USD"))
      expect(product.variants).to eq([{ id: "gid://shopify/ProductVariant/1", title: "Default", available: true,
                                        price: UcpMcp::Money.new(amount_minor: 500, currency: "USD") }])
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

    it "maps a Shopify cart node to a UcpMcp::Cart with its line items and totals array" do
      cart = described_class.cart(node)

      expect(cart.id).to eq("gid://shopify/Cart/1")
      expect(cart.totals).to eq([
                                  UcpMcp::Total.new(type: "subtotal", amount: 1000),
                                  UcpMcp::Total.new(type: "tax", amount: 100),
                                  UcpMcp::Total.new(type: "total", amount: 1100)
                                ])
      expect(cart.line_items).to eq([
                                      UcpMcp::LineItem.new(
                                        id: "gid://shopify/CartLine/1",
                                        item: UcpMcp::Item.new(id: "gid://shopify/ProductVariant/1",
                                                               title: "Cold Brew", price: 500),
                                        quantity: 2,
                                        totals: [UcpMcp::Total.new(type: "subtotal", amount: 1000),
                                                 UcpMcp::Total.new(type: "total", amount: 1000)]
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
        "id" => "gid://shopify/Order/1", "displayFulfillmentStatus" => "FULFILLED",
        "currentTotalPriceSet" => { "shopMoney" => { "amount" => "11.00", "currencyCode" => "USD" } },
        "createdAt" => "2026-07-24T00:00:00Z",
        "lineItems" => { "nodes" => [
          { "id" => "gid://shopify/LineItem/1", "quantity" => 2,
            "discountedTotalSet" => { "shopMoney" => { "amount" => "10.00", "currencyCode" => "USD" } },
            "variant" => { "id" => "gid://shopify/ProductVariant/1", "title" => "Default",
                           "price" => { "amount" => "5.00", "currencyCode" => "USD" } } }
        ] }
      }
    end

    it "maps a Shopify order node to a UcpMcp::Order" do
      order = described_class.order(node)

      expect(order.id).to eq("gid://shopify/Order/1")
      expect(order.status).to eq("FULFILLED")
      expect(order.totals).to eq([UcpMcp::Total.new(type: "total", amount: 1100)])
      expect(order.line_items.first.quantity).to eq(2)
    end
  end
end
