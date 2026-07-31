require "spec_helper"

RSpec.describe Portage::Ucp::Instagram::Mapper do
  describe ".money" do
    it "parses Meta's combined amount+currency price string" do
      expect(described_class.money("25.00 USD")).to eq(Portage::Ucp::Money.new(amount_minor: 2500, currency: "USD"))
    end
  end

  describe ".product" do
    let(:node) do
      { "id" => "1", "name" => "Handmade Mug", "description" => "desc", "price" => "25.00 USD",
        "availability" => "in stock", "url" => "https://merchant.example.com/products/mug" }
    end

    it "maps a catalog product with no item_group_id siblings to its own single implicit variant" do
      product = described_class.product(node)

      expect(product.id).to eq("1")
      expect(product.price).to eq(Portage::Ucp::Money.new(amount_minor: 2500, currency: "USD"))
      expect(product.available).to be(true)
      expect(product.url).to eq("https://merchant.example.com/products/mug")
      expect(product.variants).to eq([{ id: "1", title: "Handmade Mug", available: true,
                                        price: Portage::Ucp::Money.new(amount_minor: 2500, currency: "USD") }])
    end

    it "is unavailable when out of stock or discontinued" do
      node["availability"] = "out of stock"
      expect(described_class.product(node).available).to be(false)
    end

    it "maps variants_detail (adapter-fetched item_group siblings) into real variants when present" do
      node["variants_detail"] = [{ "id" => "2", "name" => "Handmade Mug - Large", "price" => "30.00 USD",
                                   "availability" => "in stock" }]

      variants = described_class.product(node).variants

      expect(variants).to eq([{ id: "2", title: "Handmade Mug - Large", available: true,
                                price: Portage::Ucp::Money.new(amount_minor: 3000, currency: "USD") }])
    end
  end

  describe ".checkout" do
    let(:products) do
      [{ "id" => "1", "name" => "Handmade Mug", "price" => "25.00 USD", "quantity" => 2,
         "url" => "https://merchant.example.com/products/mug" }]
    end

    it "builds one redirect link per product, id/status caller-supplied" do
      checkout = described_class.checkout(products, id: "instagram-checkout-k1", status: "incomplete")

      expect(checkout.id).to eq("instagram-checkout-k1")
      expect(checkout.status).to eq("incomplete")
      expect(checkout.links).to eq([Portage::Ucp::Link.new(type: "checkout",
                                                           url: "https://merchant.example.com/products/mug",
                                                           title: "Handmade Mug")])
      expect(checkout.totals.find { |t| t.type == "total" }.amount).to eq(5000)
    end
  end

  describe ".order" do
    let(:node) do
      { "id" => "999", "order_status" => { "state" => "COMPLETED" },
        "estimated_payment_details" => { "subtotal" => { "amount" => "25.00" },
                                         "total_amount" => { "amount" => "28.00", "currency" => "USD" } },
        "items" => { "data" => [{ "id" => "li_1", "retailer_id" => "SKU1", "product_name" => "Handmade Mug",
                                  "quantity" => 1, "price_per_unit" => { "amount" => "25.00" } }] } }
    end

    it "maps a Commerce Order, leaving checkout_id/permalink_url blank" do
      order = described_class.order(node)

      expect(order.id).to eq("999")
      expect(order.checkout_id).to eq("")
      expect(order.permalink_url).to eq("")
      expect(order.totals).to eq([Portage::Ucp::Total.new(type: "subtotal", amount: 2500),
                                  Portage::Ucp::Total.new(type: "total", amount: 2800)])
      expect(order.line_items.first.status).to eq("fulfilled")
    end

    it "derives processing/removed status from order_status.state" do
      node["order_status"]["state"] = "IN_PROGRESS"
      expect(described_class.order(node).line_items.first.status).to eq("processing")

      node["order_status"]["state"] = "CANCELLED"
      expect(described_class.order(node).line_items.first.status).to eq("removed")
    end
  end
end
