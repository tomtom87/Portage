require "spec_helper"

RSpec.describe Portage::Ucp::Etsy::Mapper do
  describe ".money" do
    it "treats amount as already-minor-units, unlike every other adapter's decimal-string price" do
      expect(described_class.money({ "amount" => 2500, "divisor" => 100, "currency_code" => "USD" }))
        .to eq(Portage::Ucp::Money.new(amount_minor: 2500, currency: "USD"))
    end
  end

  describe ".product" do
    let(:node) do
      { "listing_id" => 1, "title" => "Handmade Mug", "description" => "desc",
        "price" => { "amount" => 2500, "divisor" => 100, "currency_code" => "USD" },
        "quantity" => 5, "state" => "active", "url" => "https://www.etsy.com/listing/1/handmade-mug" }
    end

    it "maps a listing with no inventory variation to its own single implicit variant" do
      product = described_class.product(node)

      expect(product.id).to eq("1")
      expect(product.price).to eq(Portage::Ucp::Money.new(amount_minor: 2500, currency: "USD"))
      expect(product.available).to be(true)
      expect(product.url).to eq("https://www.etsy.com/listing/1/handmade-mug")
      expect(product.variants).to eq([{ id: "1", title: "Handmade Mug", available: true,
                                        price: Portage::Ucp::Money.new(amount_minor: 2500, currency: "USD") }])
    end

    it "is unavailable when inactive or out of stock" do
      node["state"] = "inactive"
      expect(described_class.product(node).available).to be(false)

      node["state"] = "active"
      node["quantity"] = 0
      expect(described_class.product(node).available).to be(false)
    end

    it "maps variants_detail (adapter-fetched inventory) into real variants when present" do
      node["variants_detail"] = { "products" => [
        { "product_id" => 10, "is_deleted" => false, "property_values" => [{ "values" => ["Red"] }],
          "offerings" => [{ "is_enabled" => true, "quantity" => 3,
                            "price" => { "amount" => 2500, "divisor" => 100, "currency_code" => "USD" } }] },
        { "product_id" => 11, "is_deleted" => true, "offerings" => [] }
      ] }

      variants = described_class.product(node).variants

      expect(variants).to eq([{ id: "10", title: "Red", available: true,
                                price: Portage::Ucp::Money.new(amount_minor: 2500, currency: "USD") }])
    end
  end

  describe ".checkout" do
    let(:listings) do
      [{ "listing_id" => 1, "title" => "Handmade Mug", "quantity" => 2,
         "price" => { "amount" => 2500, "divisor" => 100, "currency_code" => "USD" },
         "url" => "https://www.etsy.com/listing/1/handmade-mug" }]
    end

    it "builds one redirect link per listing, id/status caller-supplied" do
      checkout = described_class.checkout(listings, id: "etsy-checkout-k1", status: "incomplete")

      expect(checkout.id).to eq("etsy-checkout-k1")
      expect(checkout.status).to eq("incomplete")
      expect(checkout.links).to eq([Portage::Ucp::Link.new(type: "checkout",
                                                           url: "https://www.etsy.com/listing/1/handmade-mug",
                                                           title: "Handmade Mug")])
      expect(checkout.totals.find { |t| t.type == "total" }.amount).to eq(5000)
    end
  end

  describe ".order" do
    let(:node) do
      { "receipt_id" => 99, "is_shipped" => true, "status" => "completed",
        "subtotal" => { "amount" => 2500, "divisor" => 100, "currency_code" => "USD" },
        "total_price" => { "amount" => 2800, "divisor" => 100, "currency_code" => "USD" },
        "transactions" => [{ "transaction_id" => 1, "listing_id" => 1, "title" => "Handmade Mug", "quantity" => 1,
                             "price" => { "amount" => 2500, "divisor" => 100, "currency_code" => "USD" } }] }
    end

    it "maps a receipt to an Order, leaving checkout_id/permalink_url blank" do
      order = described_class.order(node)

      expect(order.id).to eq("99")
      expect(order.checkout_id).to eq("")
      expect(order.permalink_url).to eq("")
      expect(order.totals).to eq([Portage::Ucp::Total.new(type: "subtotal", amount: 2500),
                                  Portage::Ucp::Total.new(type: "total", amount: 2800)])
      expect(order.line_items.first.status).to eq("fulfilled")
    end

    it "derives processing/removed line item status from is_shipped/status" do
      node["is_shipped"] = false
      expect(described_class.order(node).line_items.first.status).to eq("processing")

      node["status"] = "canceled"
      expect(described_class.order(node).line_items.first.status).to eq("removed")
    end
  end
end
