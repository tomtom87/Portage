require "spec_helper"

RSpec.describe Portage::Ucp::Etsy::Adapter do
  let(:client) { Portage::Ucp::Etsy::Client.new(access_token: "acc-tok", api_key: "keystring") }
  let(:adapter) { described_class.new(client: client, shop_id: "shop_1") }

  let(:listing_node) do
    { "listing_id" => 1, "title" => "Handmade Mug", "description" => "desc",
      "price" => { "amount" => 2500, "divisor" => 100, "currency_code" => "USD" },
      "quantity" => 5, "state" => "active", "url" => "https://www.etsy.com/listing/1/handmade-mug" }
  end

  describe "capability advertisement (§2.1)" do
    it "advertises checkout (create/get overridden) but not cart or identity" do
      registry = Portage::Ucp::CapabilityRegistry.default
      advertised_names = registry.advertised(adapter).map(&:name)

      expect(advertised_names).to include("dev.ucp.shopping.catalog", "dev.ucp.shopping.checkout",
                                          "dev.ucp.shopping.order")
      expect(advertised_names).not_to include("dev.ucp.shopping.cart", "dev.ucp.shopping.identity")
    end

    it "raises NotImplementedError for update_checkout/complete_checkout/cancel_checkout" do
      expect { adapter.update_checkout(checkout_id: "x", line_items: [], idempotency_key: "k") }
        .to raise_error(Portage::Ucp::NotImplementedError)
      expect { adapter.complete_checkout(checkout_id: "x", payment_token: "t", idempotency_key: "k") }
        .to raise_error(Portage::Ucp::NotImplementedError)
      expect { adapter.cancel_checkout(checkout_id: "x", idempotency_key: "k") }
        .to raise_error(Portage::Ucp::NotImplementedError)
    end
  end

  describe "#search_catalog" do
    it "filters a page of active listings by title client-side" do
      stub_request(:get, "https://api.etsy.com/v3/application/shops/shop_1/listings/active?limit=100")
        .to_return(status: 200, body: { results: [listing_node, listing_node.merge("listing_id" => 2,
                                                                                   "title" => "Wool Scarf")] }.to_json)

      products = adapter.search_catalog(query: "mug", limit: 10)

      expect(products.size).to eq(1)
      expect(products.first.title).to eq("Handmade Mug")
    end
  end

  describe "#get_product" do
    it "fetches inventory before mapping variants" do
      stub_request(:get, "https://api.etsy.com/v3/application/listings/1").to_return(status: 200,
                                                                                     body: listing_node.to_json)
      stub_request(:get, "https://api.etsy.com/v3/application/listings/1/inventory")
        .to_return(status: 200, body: { products: [] }.to_json)

      product = adapter.get_product(product_id: 1)

      expect(product).to be_a(Portage::Ucp::Product)
      expect(product.variants).to eq([])
    end

    it "returns nil for a listing the API doesn't find" do
      stub_request(:get, "https://api.etsy.com/v3/application/listings/999")
        .to_return(status: 404, body: { error: "Listing not found" }.to_json)

      expect(adapter.get_product(product_id: 999)).to be_nil
    end
  end

  describe "#create_checkout / #get_checkout" do
    it "builds an in-memory redirect Checkout and reads it back by id" do
      stub_request(:get, "https://api.etsy.com/v3/application/listings/1").to_return(status: 200,
                                                                                     body: listing_node.to_json)

      checkout = adapter.create_checkout(line_items: [{ product_id: 1, quantity: 2 }], idempotency_key: "k1")

      expect(checkout.links.first.url).to eq("https://www.etsy.com/listing/1/handmade-mug")
      expect(adapter.get_checkout(checkout_id: checkout.id)).to equal(checkout)
    end

    it "dedups by idempotency_key instead of re-fetching listings (§9a)" do
      stub = stub_request(:get, "https://api.etsy.com/v3/application/listings/1")
             .to_return(status: 200, body: listing_node.to_json)

      first = adapter.create_checkout(line_items: [{ product_id: 1, quantity: 1 }], idempotency_key: "dupe")
      second = adapter.create_checkout(line_items: [{ product_id: 1, quantity: 1 }], idempotency_key: "dupe")

      expect(second).to equal(first)
      expect(stub).to have_been_requested.once
    end

    it "returns nil for a checkout id this Adapter instance never created" do
      expect(adapter.get_checkout(checkout_id: "unknown")).to be_nil
    end
  end

  describe "#get_order" do
    it "queries the shop receipts endpoint and maps the result" do
      stub_request(:get, "https://api.etsy.com/v3/application/shops/shop_1/receipts/99")
        .to_return(status: 200, body: { receipt_id: 99, is_shipped: true, status: "completed",
                                        subtotal: { amount: 2500, divisor: 100, currency_code: "USD" },
                                        total_price: { amount: 2800, divisor: 100, currency_code: "USD" },
                                        transactions: [] }.to_json)

      order = adapter.get_order(order_id: 99)

      expect(order).to be_a(Portage::Ucp::Order)
      expect(order.checkout_id).to eq("")
    end

    it "returns nil for a receipt the API doesn't find" do
      stub_request(:get, "https://api.etsy.com/v3/application/shops/shop_1/receipts/999")
        .to_return(status: 404, body: { error: "Receipt not found" }.to_json)

      expect(adapter.get_order(order_id: 999)).to be_nil
    end
  end
end
