require "spec_helper"

RSpec.describe Portage::Ucp::Magento::Mapper do
  describe ".money" do
    it "converts a decimal amount to integer minor units without float drift" do
      money = described_class.money(19.99, "USD")

      expect(money).to eq(Portage::Ucp::Money.new(amount_minor: 1999, currency: "USD"))
    end
  end

  describe ".product" do
    let(:node) do
      { "sku" => "cold-brew", "name" => "Cold Brew", "price" => 5.0, "status" => 1,
        "custom_attributes" => [{ "attribute_code" => "url_key", "value" => "cold-brew" },
                                { "attribute_code" => "description", "value" => "desc" }],
        "extension_attributes" => { "stock_item" => { "is_in_stock" => true } } }
    end

    it "maps a simple Magento product to a Portage::Ucp::Product, treating it as its own single variant" do
      product = described_class.product(node, currency: "USD", site_url: "https://shop.example.com")

      expect(product.id).to eq("cold-brew")
      expect(product.description).to eq("desc")
      expect(product.price).to eq(Portage::Ucp::Money.new(amount_minor: 500, currency: "USD"))
      expect(product.available).to be(true)
      expect(product.url).to eq("https://shop.example.com/cold-brew.html")
      expect(product.variants).to eq([{ id: "cold-brew", title: "Cold Brew", available: true,
                                        price: Portage::Ucp::Money.new(amount_minor: 500, currency: "USD") }])
    end

    it "maps children_detail (adapter-fetched) into real variants when present" do
      node["type_id"] = "configurable"
      node["children_detail"] = [
        { "sku" => "cold-brew-large", "name" => "Cold Brew - Large", "price" => 6.0, "status" => 1,
          "extension_attributes" => { "stock_item" => { "is_in_stock" => true } } }
      ]

      variants = described_class.product(node, currency: "USD").variants

      expect(variants).to eq([{ id: "cold-brew-large", title: "Cold Brew - Large", available: true,
                                price: Portage::Ucp::Money.new(amount_minor: 600, currency: "USD") }])
    end

    it "treats a missing stock_item as available (extension_attributes not always populated)" do
      node.delete("extension_attributes")

      expect(described_class.product(node, currency: "USD").available).to be(true)
    end

    it "is unavailable when disabled or out of stock" do
      node["status"] = 2
      expect(described_class.product(node, currency: "USD").available).to be(false)

      node["status"] = 1
      node["extension_attributes"]["stock_item"]["is_in_stock"] = false
      expect(described_class.product(node, currency: "USD").available).to be(false)
    end
  end

  describe ".cart / .checkout" do
    let(:merged_items) do
      [{ "item_id" => 1, "sku" => "cold-brew", "name" => "Cold Brew", "qty" => 2, "price" => 5.0,
         "row_total" => "10.0000", "tax_amount" => "1.0000" }]
    end

    it "maps merged guest-cart items to a Portage::Ucp::Cart, using the caller-supplied id/currency" do
      cart = described_class.cart(merged_items, id: "cart_tok_1", currency: "USD")

      expect(cart.id).to eq("cart_tok_1")
      expect(cart.currency).to eq("USD")
      expect(cart.totals).to eq([
                                  Portage::Ucp::Total.new(type: "subtotal", amount: 1000),
                                  Portage::Ucp::Total.new(type: "tax", amount: 100),
                                  Portage::Ucp::Total.new(type: "total", amount: 1100)
                                ])
      expect(cart.line_items).to eq([
                                      Portage::Ucp::LineItem.new(
                                        id: "1",
                                        item: Portage::Ucp::Item.new(id: "cold-brew", title: "Cold Brew", price: 500),
                                        quantity: 2,
                                        totals: [Portage::Ucp::Total.new(type: "subtotal", amount: 1000),
                                                 Portage::Ucp::Total.new(type: "total", amount: 1000)]
                                      )
                                    ])
    end

    it "sets Checkout status/id/currency from the caller, and includes required links" do
      checkout = described_class.checkout(merged_items, id: "cart_tok_1", currency: "USD", status: "completed")

      expect(checkout.id).to eq("cart_tok_1")
      expect(checkout.status).to eq("completed")
      expect(checkout.links).to eq([])
    end
  end

  describe ".order" do
    let(:node) do
      { "entity_id" => 42, "order_currency_code" => "USD", "status" => "complete",
        "subtotal" => "10.0000", "grand_total" => "11.0000",
        "items" => [{ "item_id" => 1, "sku" => "cold-brew", "name" => "Cold Brew", "qty_ordered" => 2,
                      "price" => 5.0, "row_total" => "10.0000" }] }
    end

    it "maps a Magento order to an Order, leaving permalink_url blank and checkout_id caller-supplied" do
      order = described_class.order(node)

      expect(order.id).to eq("42")
      expect(order.checkout_id).to eq("")
      expect(order.permalink_url).to eq("")
      expect(order.totals).to eq([Portage::Ucp::Total.new(type: "subtotal", amount: 1000),
                                  Portage::Ucp::Total.new(type: "total", amount: 1100)])
      expect(order.line_items.first.status).to eq("fulfilled")
      expect(order.line_items.first.quantity).to eq({ original: 2, total: 2, fulfilled: 2 })
    end

    it "threads a caller-supplied checkout_id through, same as Portage::Ucp::WooCommerce::Mapper.order" do
      expect(described_class.order(node, checkout_id: "cart_tok_1").checkout_id).to eq("cart_tok_1")
    end

    it "derives a coarse line item status uniformly from the order's own status" do
      node["status"] = "canceled"

      expect(described_class.order(node).line_items.first.status).to eq("removed")
    end
  end
end
