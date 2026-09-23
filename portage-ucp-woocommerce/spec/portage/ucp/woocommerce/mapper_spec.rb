require "spec_helper"

RSpec.describe Portage::Ucp::WooCommerce::Mapper do
  describe ".money" do
    it "converts a decimal amount string to integer minor units without float drift" do
      money = described_class.money("19.99", "USD")

      expect(money).to eq(Portage::Ucp::Money.new(amount_minor: 1999, currency: "USD"))
    end
  end

  describe ".product" do
    let(:node) do
      { "id" => 1, "name" => "Cold Brew", "description" => "desc", "permalink" => "https://shop.example.com/cold-brew",
        "price" => "5.00", "stock_status" => "instock", "type" => "simple" }
    end

    it "maps a simple WooCommerce product to a Portage::Ucp::Product, treating it as its own single variant" do
      product = described_class.product(node, currency: "USD")

      expect(product.id).to eq("1")
      expect(product.price_range).to eq(
        Portage::Ucp::PriceRange.new(min: Portage::Ucp::Price.new(amount: 500, currency: "USD"),
                                     max: Portage::Ucp::Price.new(amount: 500, currency: "USD"))
      )
      variant = product.variants.first
      expect(variant.id).to eq("1")
      expect(variant.title).to eq("Cold Brew")
      expect(variant.availability).to eq({ "available" => true })
      expect(variant.price).to eq(Portage::Ucp::Price.new(amount: 500, currency: "USD"))
    end

    it "maps variations_detail (adapter-fetched) into real variants when present" do
      node["variations_detail"] = [
        { "id" => 2, "price" => "6.00", "stock_status" => "instock",
          "attributes" => [{ "name" => "Size", "option" => "Large" }] }
      ]

      variant = described_class.product(node, currency: "USD").variants.first

      expect(variant.id).to eq("2")
      expect(variant.title).to eq("Large")
      expect(variant.availability).to eq({ "available" => true })
      expect(variant.price).to eq(Portage::Ucp::Price.new(amount: 600, currency: "USD"))
    end

    it "treats stock_status other than outofstock as available" do
      node["stock_status"] = "onbackorder"

      expect(described_class.product(node, currency: "USD").variants.first.availability).to eq({ "available" => true })
    end
  end

  describe ".cart / .checkout" do
    let(:node) do
      {
        "items" => [
          { "key" => "abc123", "id" => 1, "name" => "Cold Brew", "quantity" => 2,
            "prices" => { "price" => "500", "currency_minor_unit" => 2 } }
        ],
        "totals" => { "currency_code" => "USD", "total_items" => "1000", "total_tax" => "100",
                      "total_price" => "1100" }
      }
    end

    it "maps a Store API cart node to a Portage::Ucp::Cart, using the caller-supplied id" do
      cart = described_class.cart(node, id: "tok_1")

      expect(cart.id).to eq("tok_1")
      expect(cart.currency).to eq("USD")
      expect(cart.totals).to eq([
                                  Portage::Ucp::Total.new(type: "subtotal", amount: 1000),
                                  Portage::Ucp::Total.new(type: "tax", amount: 100),
                                  Portage::Ucp::Total.new(type: "total", amount: 1100)
                                ])
      expect(cart.line_items).to eq([
                                      Portage::Ucp::LineItem.new(
                                        id: "abc123",
                                        item: Portage::Ucp::Item.new(id: "1", title: "Cold Brew", price: 500),
                                        quantity: 2,
                                        totals: [Portage::Ucp::Total.new(type: "subtotal", amount: 1000),
                                                 Portage::Ucp::Total.new(type: "total", amount: 1000)]
                                      )
                                    ])
    end

    it "sets Checkout status and id from the caller, and omits links once completed" do
      checkout = described_class.checkout(node, id: "tok_1", status: "completed", site_url: "https://shop.example")

      expect(checkout.id).to eq("tok_1")
      expect(checkout.status).to eq("completed")
      expect(checkout.links).to eq([])
    end

    # The ?session= token is what lets the classic checkout page bridge into the same cart.
    it "emits a resume-checkout link built from site_url, carrying the cart token as ?session=" do
      checkout = described_class.checkout(node, id: "tok_1", status: "incomplete", site_url: "https://shop.example")

      expect(checkout.links).to eq([
                                     Portage::Ucp::Link.new(type: "resume-checkout",
                                                            url: "https://shop.example/checkout/?session=tok_1")
                                   ])
    end

    it "URL-escapes the cart token in the ?session= link" do
      checkout = described_class.checkout(node, id: "tok.a/b+c", status: "incomplete", site_url: "https://shop.example")

      expect(checkout.links.first.url).to eq("https://shop.example/checkout/?session=tok.a%2Fb%2Bc")
    end
  end

  describe ".order" do
    let(:node) do
      { "id" => 42, "order_key" => "wc_order_abc", "currency" => "USD", "status" => "completed",
        "total" => "11.00", "total_tax" => "1.00",
        "line_items" => [
          { "id" => 1, "name" => "Cold Brew", "product_id" => 1, "variation_id" => 0, "quantity" => 2,
            "price" => 5.0, "total" => "10.00" }
        ] }
    end

    it "maps a WooCommerce order to an Order, building permalink_url from the order-received pattern" do
      order = described_class.order(node, site_url: "https://shop.example.com")

      expect(order.id).to eq("42")
      expect(order.checkout_id).to eq("")
      expect(order.permalink_url).to eq("https://shop.example.com/checkout/order-received/42/?key=wc_order_abc")
      expect(order.totals).to eq([Portage::Ucp::Total.new(type: "subtotal", amount: 1000),
                                  Portage::Ucp::Total.new(type: "total", amount: 1100)])
      expect(order.line_items.first.status).to eq("fulfilled")
      expect(order.line_items.first.quantity).to eq({ original: 2, total: 2, fulfilled: 2 })
    end

    it "threads a caller-supplied checkout_id through, same as Portage::Ucp::Shopify::Mapper.order" do
      order = described_class.order(node, site_url: "https://shop.example.com", checkout_id: "tok_1")

      expect(order.checkout_id).to eq("tok_1")
    end

    it "derives a coarse line item status uniformly from the order's own status" do
      node["status"] = "cancelled"

      expect(described_class.order(node, site_url: "https://shop.example.com").line_items.first.status)
        .to eq("removed")
    end
  end
end
