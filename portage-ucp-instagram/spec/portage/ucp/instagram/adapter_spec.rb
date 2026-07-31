require "spec_helper"

RSpec.describe Portage::Ucp::Instagram::Adapter do
  let(:client) { Portage::Ucp::Instagram::Client.new(access_token: "acc-tok") }
  let(:adapter) { described_class.new(client: client, catalog_id: "catalog_1") }

  let(:product_node) do
    { "id" => "1", "name" => "Handmade Mug", "description" => "desc", "price" => "25.00 USD",
      "availability" => "in stock", "url" => "https://merchant.example.com/products/mug" }
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
    it "queries the catalog products endpoint with a name filter" do
      stub_request(:get, %r{/catalog_1/products\?})
        .to_return(status: 200, body: { data: [product_node] }.to_json)

      products = adapter.search_catalog(query: "mug", limit: 10)

      expect(products.first).to be_a(Portage::Ucp::Product)
      expect(products.first.title).to eq("Handmade Mug")
    end
  end

  describe "#get_product" do
    it "fetches item_group siblings before mapping variants" do
      stub_request(:get, "https://graph.facebook.com/v21.0/1?fields=id,name,description,price,availability,url,item_group_id")
        .to_return(status: 200, body: product_node.merge("item_group_id" => "group_1").to_json)
      stub_request(:get, %r{/catalog_1/products\?fields=id,name,availability,price})
        .to_return(status: 200, body: { data: [product_node.merge("id" => "2")] }.to_json)

      product = adapter.get_product(product_id: "1")

      expect(product.variants.first[:id]).to eq("2")
    end

    it "returns nil for a product the API doesn't find" do
      stub_request(:get, "https://graph.facebook.com/v21.0/999?fields=id,name,description,price,availability,url,item_group_id")
        .to_return(status: 404, body: { error: { message: "Unsupported get request" } }.to_json)

      expect(adapter.get_product(product_id: "999")).to be_nil
    end
  end

  describe "#create_checkout / #get_checkout" do
    it "builds an in-memory redirect Checkout and reads it back by id" do
      stub_request(:get, "https://graph.facebook.com/v21.0/1?fields=id,name,price,url")
        .to_return(status: 200, body: product_node.to_json)

      checkout = adapter.create_checkout(line_items: [{ product_id: "1", quantity: 1 }], idempotency_key: "k1")

      expect(checkout.links.first.url).to eq("https://merchant.example.com/products/mug")
      expect(adapter.get_checkout(checkout_id: checkout.id)).to equal(checkout)
    end

    it "dedups by idempotency_key instead of re-fetching products (§9a)" do
      stub = stub_request(:get, "https://graph.facebook.com/v21.0/1?fields=id,name,price,url")
             .to_return(status: 200, body: product_node.to_json)

      first = adapter.create_checkout(line_items: [{ product_id: "1", quantity: 1 }], idempotency_key: "dupe")
      second = adapter.create_checkout(line_items: [{ product_id: "1", quantity: 1 }], idempotency_key: "dupe")

      expect(second).to equal(first)
      expect(stub).to have_been_requested.once
    end

    it "returns nil for a checkout id this Adapter instance never created" do
      expect(adapter.get_checkout(checkout_id: "unknown")).to be_nil
    end
  end

  describe "#get_order" do
    it "queries the Graph API order endpoint and maps the result" do
      stub_request(:get, %r{/999\?fields=id,order_status})
        .to_return(status: 200, body: { id: "999", order_status: { state: "COMPLETED" },
                                        estimated_payment_details: { subtotal: { amount: "25.00" },
                                                                     total_amount: { amount: "25.00" } },
                                        items: { data: [] } }.to_json)

      order = adapter.get_order(order_id: "999")

      expect(order).to be_a(Portage::Ucp::Order)
      expect(order.checkout_id).to eq("")
    end

    it "returns nil when Meta 403s (website-checkout merchants have no Meta-side order)" do
      stub_request(:get, %r{/999\?fields=id,order_status})
        .to_return(status: 403, body: { error: { message: "Unsupported get request" } }.to_json)

      expect(adapter.get_order(order_id: "999")).to be_nil
    end
  end
end
