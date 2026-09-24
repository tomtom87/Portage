require "spec_helper"

RSpec.describe Portage::Ucp::Instagram::Mapper do
  describe ".money" do
    it "parses Meta's combined amount+currency price string" do
      expect(described_class.money("25.00 USD")).to eq(Portage::Ucp::Money.new(amount_minor: 2500, currency: "USD"))
    end

    it "defaults to zero/nil for a nil price" do
      expect(described_class.money(nil)).to eq(Portage::Ucp::Money.new(amount_minor: 0, currency: nil))
    end

    it "parses a currency-less price string with a nil currency" do
      expect(described_class.money("25.00")).to eq(Portage::Ucp::Money.new(amount_minor: 2500, currency: nil))
    end

    it "degrades a malformed (non-numeric) amount to zero rather than raising" do
      expect(described_class.money("N/A USD")).to eq(Portage::Ucp::Money.new(amount_minor: 0, currency: "USD"))
    end
  end

  describe ".price" do
    it "defaults to zero/nil for a nil price" do
      expect(described_class.price(nil)).to eq(Portage::Ucp::Price.new(amount: 0, currency: nil))
    end

    it "degrades a malformed amount to zero rather than raising" do
      expect(described_class.price("not-a-number USD")).to eq(Portage::Ucp::Price.new(amount: 0, currency: "USD"))
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
      expect(product.price_range).to eq(
        Portage::Ucp::PriceRange.new(min: Portage::Ucp::Price.new(amount: 2500, currency: "USD"),
                                     max: Portage::Ucp::Price.new(amount: 2500, currency: "USD"))
      )
      expect(product.url).to eq("https://merchant.example.com/products/mug")
      variant = product.variants.first
      expect(variant.id).to eq("1")
      expect(variant.title).to eq("Handmade Mug")
      expect(variant.availability).to eq({ "available" => true })
      expect(variant.price).to eq(Portage::Ucp::Price.new(amount: 2500, currency: "USD"))
    end

    it "is unavailable when out of stock or discontinued" do
      node["availability"] = "out of stock"
      expect(described_class.product(node).variants.first.availability).to eq({ "available" => false })
    end

    it "maps variants_detail (adapter-fetched item_group siblings) into real variants when present" do
      node["variants_detail"] = [{ "id" => "2", "name" => "Handmade Mug - Large", "price" => "30.00 USD",
                                   "availability" => "in stock" }]

      variant = described_class.product(node).variants.first

      expect(variant.id).to eq("2")
      expect(variant.title).to eq("Handmade Mug - Large")
      expect(variant.availability).to eq({ "available" => true })
      expect(variant.price).to eq(Portage::Ucp::Price.new(amount: 3000, currency: "USD"))
    end

    it "returns an empty variants_detail as no variants, distinct from an absent one" do
      node["variants_detail"] = []
      expect(described_class.product(node).variants).to eq([])
    end

    it "degrades a nil/missing price to a zero price_range rather than raising" do
      node.delete("price")
      product = described_class.product(node)

      expect(product.price_range).to eq(
        Portage::Ucp::PriceRange.new(min: Portage::Ucp::Price.new(amount: 0, currency: nil),
                                     max: Portage::Ucp::Price.new(amount: 0, currency: nil))
      )
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

    it "builds an empty checkout for no products rather than raising" do
      checkout = described_class.checkout([], id: "instagram-checkout-empty", status: "incomplete")

      expect(checkout.line_items).to eq([])
      expect(checkout.currency).to be_nil
      expect(checkout.totals.find { |t| t.type == "total" }.amount).to eq(0)
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

    it "defaults an unmapped order_status.state to processing (§from_table) rather than raising" do
      node["order_status"]["state"] = "SOME_FUTURE_STATE_NOT_YET_MAPPED"
      expect(described_class.order(node).line_items.first.status).to eq("processing")
    end

    it "maps an order with an empty items.data to no line items rather than raising" do
      node["items"] = { "data" => [] }
      order = described_class.order(node)

      expect(order.line_items).to eq([])
    end

    it "maps an order with items.data entirely absent to no line items rather than raising" do
      node.delete("items")
      order = described_class.order(node)

      expect(order.line_items).to eq([])
    end

    it "degrades a malformed order_status/estimated_payment_details (not a Hash) rather than raising" do
      node["order_status"] = "COMPLETED" # not the documented {"state" => ...} shape
      node["estimated_payment_details"] = nil

      order = described_class.order(node)

      expect(order.line_items.first.status).to eq("processing")
      expect(order.totals).to eq([Portage::Ucp::Total.new(type: "subtotal", amount: 0),
                                  Portage::Ucp::Total.new(type: "total", amount: 0)])
      expect(order.currency).to be_nil
    end

    it "degrades a line item with a missing quantity/price_per_unit rather than raising" do
      node["items"]["data"] = [{ "id" => "li_1", "retailer_id" => "SKU1", "product_name" => "Handmade Mug" }]

      line_item = described_class.order(node).line_items.first

      expect(line_item.quantity).to eq({ original: 0, total: 0, fulfilled: 0 })
      expect(line_item.item.price).to eq(0)
    end
  end
end
