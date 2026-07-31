require "spec_helper"

RSpec.describe Portage::Ucp::BigCommerce::Mapper do
  describe ".money" do
    it "converts a decimal amount to integer minor units without float drift" do
      money = described_class.money(19.99, "USD")

      expect(money).to eq(Portage::Ucp::Money.new(amount_minor: 1999, currency: "USD"))
    end
  end

  describe ".product" do
    let(:node) do
      { "id" => 1, "name" => "Cold Brew", "description" => "desc", "price" => 5.0, "availability" => "available",
        "custom_url" => { "url" => "/cold-brew/" } }
    end

    it "maps a simple BigCommerce product, treating it as its own single variant" do
      product = described_class.product(node, currency: "USD", site_url: "https://shop.example.com")

      expect(product.id).to eq("1")
      expect(product.price).to eq(Portage::Ucp::Money.new(amount_minor: 500, currency: "USD"))
      expect(product.available).to be(true)
      expect(product.url).to eq("https://shop.example.com/cold-brew/")
      expect(product.variants).to eq([{ id: "1", title: "Cold Brew", available: true,
                                        price: Portage::Ucp::Money.new(amount_minor: 500, currency: "USD") }])
    end

    it "maps real variants when present, falling back to the parent price when unset" do
      node["variants"] = [
        { "id" => 2, "price" => 0, "purchasing_disabled" => false,
          "option_values" => [{ "label" => "Large" }] }
      ]

      variants = described_class.product(node, currency: "USD", site_url: "https://shop.example.com").variants

      expect(variants).to eq([{ id: "2", title: "Large", available: true,
                                price: Portage::Ucp::Money.new(amount_minor: 500, currency: "USD") }])
    end

    it "treats availability other than disabled as available" do
      node["availability"] = "preorder"

      expect(described_class.product(node, currency: "USD", site_url: "https://shop.example.com").available)
        .to be(true)
    end
  end

  describe ".cart / .checkout" do
    let(:node) do
      {
        "currency" => { "code" => "USD" },
        "base_amount" => 10.0,
        "cart_amount" => 10.0,
        "line_items" => {
          "physical_items" => [
            { "id" => "item_1", "product_id" => 1, "name" => "Cold Brew", "quantity" => 2,
              "sale_price" => 5.0, "extended_sale_price" => 10.0, "extended_list_price" => 10.0 }
          ]
        }
      }
    end

    it "maps a v3 cart node to a Portage::Ucp::Cart" do
      cart = described_class.cart(node, id: "cart_1")

      expect(cart.id).to eq("cart_1")
      expect(cart.currency).to eq("USD")
      expect(cart.totals).to eq([Portage::Ucp::Total.new(type: "subtotal", amount: 1000),
                                 Portage::Ucp::Total.new(type: "total", amount: 1000)])
      expect(cart.line_items.first.item.id).to eq("1")
      expect(cart.line_items.first.quantity).to eq(2)
    end

    it "builds Checkout from an embedded cart plus checkout-level totals, using the caller-supplied status" do
      checkout_node = { "cart" => node, "subtotal" => 10.0, "tax_total" => 1.0, "grand_total" => 11.0 }

      checkout = described_class.checkout(checkout_node, id: "cart_1", status: "incomplete")

      expect(checkout.status).to eq("incomplete")
      expect(checkout.totals).to eq([Portage::Ucp::Total.new(type: "subtotal", amount: 1000),
                                     Portage::Ucp::Total.new(type: "tax", amount: 100),
                                     Portage::Ucp::Total.new(type: "total", amount: 1100)])
      expect(checkout.links).to eq([])
    end
  end

  describe ".order" do
    let(:node) do
      { "id" => 42, "currency_code" => "USD", "status_id" => 11, "subtotal_ex_tax" => "10.00",
        "total_inc_tax" => "11.00" }
    end
    let(:products) do
      [{ "id" => 1, "product_id" => 1, "name" => "Cold Brew", "quantity" => 2, "price_ex_tax" => "5.00",
         "total_ex_tax" => "10.00", "total_inc_tax" => "11.00" }]
    end

    it "maps a v2 order plus its separately-fetched products to an Order" do
      order = described_class.order(node, products: products, site_url: "https://shop.example.com")

      expect(order.id).to eq("42")
      expect(order.checkout_id).to eq("")
      expect(order.permalink_url).to eq("https://shop.example.com/account.php?action=order_status&order_id=42")
      expect(order.totals).to eq([Portage::Ucp::Total.new(type: "subtotal", amount: 1000),
                                  Portage::Ucp::Total.new(type: "total", amount: 1100)])
      expect(order.line_items.first.status).to eq("processing")
    end

    it "threads a caller-supplied checkout_id through" do
      order = described_class.order(node, products: products, site_url: "https://shop.example.com",
                                          checkout_id: "cart_1")

      expect(order.checkout_id).to eq("cart_1")
    end

    it "derives fulfilled/removed line item status from the order's fixed status_id enum" do
      node["status_id"] = 2 # Shipped

      expect(described_class.order(node, products: products, site_url: "https://shop.example.com")
        .line_items.first.status).to eq("fulfilled")

      node["status_id"] = 5 # Cancelled

      expect(described_class.order(node, products: products, site_url: "https://shop.example.com")
        .line_items.first.status).to eq("removed")
    end
  end
end
