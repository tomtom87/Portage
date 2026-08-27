require "spec_helper"

RSpec.describe Portage::Ucp::Wix::Mapper do
  describe ".money" do
    it "converts a decimal amount string to integer minor units without float drift" do
      money = described_class.money("19.99", "USD")

      expect(money).to eq(Portage::Ucp::Money.new(amount_minor: 1999, currency: "USD"))
    end
  end

  describe ".product" do
    let(:node) do
      {
        "id" => "prod_1", "name" => "Cold Brew", "description" => "desc",
        "priceData" => { "price" => 5.0, "currency" => "USD" },
        "stock" => { "inStock" => true },
        "productPageUrl" => { "base" => "https://site.wixsite.com/store", "path" => "/product-page/cold-brew" },
        "variants" => [
          { "id" => "var_1", "choices" => { "Size" => "Large" }, "stock" => { "inStock" => true },
            "variant" => { "priceData" => { "price" => 6.0 } } }
        ]
      }
    end

    it "maps a Wix product node to a Portage::Ucp::Product" do
      product = described_class.product(node)

      expect(product.id).to eq("prod_1")
      expect(product.price_range).to eq(
        Portage::Ucp::PriceRange.new(min: Portage::Ucp::Price.new(amount: 500, currency: "USD"),
                                     max: Portage::Ucp::Price.new(amount: 500, currency: "USD"))
      )
      expect(product.url).to eq("https://site.wixsite.com/store/product-page/cold-brew")

      variant = product.variants.first
      expect(variant.id).to eq("var_1")
      expect(variant.title).to eq("Large")
      expect(variant.availability).to eq({ "available" => true })
      expect(variant.price).to eq(Portage::Ucp::Price.new(amount: 600, currency: "USD"))
    end

    it "falls back to the product title when a variant has no choices" do
      node["variants"].first["choices"] = {}

      expect(described_class.product(node).variants.first.title).to eq("Cold Brew")
    end

    it "synthesizes a single variant from product-level fields when the product has no variants array" do
      node["variants"] = []

      product = described_class.product(node)

      expect(product.variants.size).to eq(1)
      expect(product.variants.first.price).to eq(Portage::Ucp::Price.new(amount: 500, currency: "USD"))
    end
  end

  describe ".cart / .checkout" do
    let(:node) do
      {
        "id" => "cart_1",
        "currency" => "USD",
        "priceSummary" => { "subtotal" => { "amount" => "10.00" }, "tax" => { "amount" => "1.00" },
                            "total" => { "amount" => "11.00" } },
        "lineItems" => [
          { "id" => "line_1", "quantity" => 2, "price" => { "amount" => "5.00" },
            "catalogReference" => { "catalogItemId" => "var_1" },
            "productName" => { "original" => "Cold Brew" } }
        ]
      }
    end

    it "maps a Wix cart node to a Portage::Ucp::Cart with its line items and totals array" do
      cart = described_class.cart(node)

      expect(cart.id).to eq("cart_1")
      expect(cart.totals).to eq([
                                  Portage::Ucp::Total.new(type: "subtotal", amount: 1000),
                                  Portage::Ucp::Total.new(type: "tax", amount: 100),
                                  Portage::Ucp::Total.new(type: "total", amount: 1100)
                                ])
      expect(cart.line_items).to eq([
                                      Portage::Ucp::LineItem.new(
                                        id: "line_1",
                                        item: Portage::Ucp::Item.new(id: "var_1", title: "Cold Brew", price: 500),
                                        quantity: 2,
                                        totals: [Portage::Ucp::Total.new(type: "subtotal", amount: 1000),
                                                 Portage::Ucp::Total.new(type: "total", amount: 1000)]
                                      )
                                    ])
    end

    it "sets Checkout status from the caller rather than any Wix field, and includes required links" do
      checkout = described_class.checkout(node, status: "completed")

      expect(checkout.status).to eq("completed")
      expect(checkout.links).to eq([])
      expect(checkout.totals.find { |t| t.type == "total" }.amount).to eq(1100)
    end
  end

  describe ".order" do
    let(:node) do
      {
        "id" => "order_1", "checkoutId" => "checkout_1", "currency" => "USD",
        "priceSummary" => { "subtotal" => { "amount" => "10.00" }, "total" => { "amount" => "10.00" } },
        "lineItems" => [
          { "id" => "line_1", "quantity" => 2, "price" => { "amount" => "5.00" }, "fulfillmentStatus" => "FULFILLED",
            "catalogReference" => { "catalogItemId" => "var_1" }, "productName" => { "original" => "Cold Brew" } }
        ]
      }
    end

    it "maps a Wix order node to an Order, reading checkout_id straight off the Wix order" do
      order = described_class.order(node)

      expect(order.id).to eq("order_1")
      expect(order.checkout_id).to eq("checkout_1")
      expect(order.permalink_url).to eq("")
      expect(order.fulfillment).to eq(Portage::Ucp::Fulfillment.new)
      expect(order.totals).to eq([Portage::Ucp::Total.new(type: "subtotal", amount: 1000),
                                  Portage::Ucp::Total.new(type: "total", amount: 1000)])
      expect(order.line_items.first.quantity).to eq({ original: 2, total: 2, fulfilled: 2 })
      expect(order.line_items.first.status).to eq("fulfilled")
    end

    it "defaults checkout_id to an empty string when Wix doesn't return one" do
      node.delete("checkoutId")

      expect(described_class.order(node).checkout_id).to eq("")
    end

    it "derives partial/processing/removed line item status from fulfillmentStatus" do
      shared = { "price" => { "amount" => "5.00" }, "catalogReference" => {}, "productName" => {} }
      partial = described_class.order_line_item(shared.merge("id" => "l1", "quantity" => 3,
                                                             "fulfillmentStatus" => "PARTIALLY_FULFILLED"))
      processing = described_class.order_line_item(shared.merge("id" => "l2", "quantity" => 3,
                                                                "fulfillmentStatus" => "NOT_FULFILLED"))
      removed = described_class.order_line_item(shared.merge("id" => "l3", "quantity" => 3,
                                                             "fulfillmentStatus" => "CANCELED"))

      expect(partial.status).to eq("partial")
      expect(processing.status).to eq("processing")
      expect(removed.status).to eq("removed")
    end
  end
end
