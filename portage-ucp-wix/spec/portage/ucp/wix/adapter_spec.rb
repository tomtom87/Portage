require "spec_helper"

RSpec.describe Portage::Ucp::Wix::Adapter do
  let(:client) { Portage::Ucp::Wix::Client.new(access_token: "site-token") }
  let(:adapter) { described_class.new(client: client) }

  let(:cart_response) do
    {
      "id" => "cart_1", "currency" => "USD",
      "priceSummary" => { "subtotal" => { "amount" => "5.00" }, "total" => { "amount" => "5.00" } },
      "lineItems" => [
        { "id" => "line_1", "quantity" => 1, "price" => { "amount" => "5.00" },
          "catalogReference" => { "catalogItemId" => "var_1" }, "productName" => { "original" => "Cold Brew" } }
      ]
    }
  end

  let(:empty_cart_response) { cart_response.merge("lineItems" => []) }

  describe "capability advertisement (§2.1)" do
    it "only advertises capabilities backed by an overridden method — no Wix identity linking" do
      registry = Portage::Ucp::CapabilityRegistry.default
      advertised_names = registry.advertised(adapter).map(&:name)

      expect(advertised_names).to include("dev.ucp.shopping.catalog", "dev.ucp.shopping.cart",
                                          "dev.ucp.shopping.checkout", "dev.ucp.shopping.order")
      expect(advertised_names).not_to include("dev.ucp.shopping.identity")
    end
  end

  describe "#search_catalog" do
    it "queries the Stores catalog and maps results to Portage::Ucp::Product" do
      stub_request(:post, "https://www.wixapis.com/stores/v1/products/query")
        .to_return(status: 200, body: { products: [
          { id: "prod_1", name: "Cold Brew", description: "desc",
            priceData: { price: 5.0, currency: "USD" }, stock: { inStock: true }, variants: [] }
        ] }.to_json)

      products = adapter.search_catalog(query: "brew", limit: 10)

      expect(products.first).to be_a(Portage::Ucp::Product)
      expect(products.first.title).to eq("Cold Brew")
    end
  end

  describe "#get_product" do
    it "returns nil for a product the API doesn't find" do
      stub_request(:get, "https://www.wixapis.com/stores/v1/products/nonexistent")
        .to_return(status: 200, body: { product: nil }.to_json)

      expect(adapter.get_product(product_id: "nonexistent")).to be_nil
    end
  end

  describe "#get_cart" do
    it "queries the eCommerce Carts API and maps the result to a Portage::Ucp::Cart" do
      stub_request(:get, "https://www.wixapis.com/ecom/v1/carts/cart_1")
        .to_return(status: 200, body: { cart: cart_response }.to_json)

      cart = adapter.get_cart(cart_id: "cart_1")

      expect(cart.line_items.size).to eq(1)
      expect(cart.totals.find { |t| t.type == "total" }.amount).to eq(500)
    end
  end

  describe "#create_cart" do
    it "sends the product_id as the line item's catalogItemId, scoped to the Stores app" do
      stub = stub_request(:post, "https://www.wixapis.com/ecom/v1/carts")
             .with(body: { lineItems: [{ catalogReference: { catalogItemId: "var_1",
                                                             appId: described_class::STORES_APP_ID },
                                         quantity: 1 }] }.to_json)
             .to_return(status: 200, body: { cart: cart_response }.to_json)

      cart = adapter.create_cart(line_items: [{ product_id: "var_1", quantity: 1 }], idempotency_key: "k1")

      expect(cart).to be_a(Portage::Ucp::Cart)
      expect(stub).to have_been_requested
    end

    it "dedups by idempotency_key instead of re-issuing the request (§9a)" do
      stub = stub_request(:post, "https://www.wixapis.com/ecom/v1/carts")
             .to_return(status: 200, body: { cart: cart_response }.to_json)

      first = adapter.create_cart(line_items: [{ product_id: "var_1", quantity: 1 }], idempotency_key: "dupe")
      second = adapter.create_cart(line_items: [{ product_id: "var_1", quantity: 1 }], idempotency_key: "dupe")

      expect(second).to equal(first)
      expect(stub).to have_been_requested.once
    end
  end

  describe "#update_cart" do
    it "replaces all lines by removing the current ones then adding the desired ones" do
      stub_request(:get, "https://www.wixapis.com/ecom/v1/carts/cart_1")
        .to_return(status: 200, body: { cart: cart_response }.to_json)
      remove_stub = stub_request(:post, "https://www.wixapis.com/ecom/v1/carts/cart_1/remove-line-items")
                    .to_return(status: 200, body: { cart: empty_cart_response }.to_json)
      add_stub = stub_request(:post, "https://www.wixapis.com/ecom/v1/carts/cart_1/add-line-items")
                 .to_return(status: 200, body: { cart: cart_response }.to_json)

      cart = adapter.update_cart(cart_id: "cart_1", line_items: [{ product_id: "var_1", quantity: 1 }],
                                 idempotency_key: "k1")

      expect(cart).to be_a(Portage::Ucp::Cart)
      expect(remove_stub).to have_been_requested
      expect(add_stub).to have_been_requested
    end
  end

  describe "#cancel_cart" do
    it "deletes the cart and returns its last-known state" do
      stub_request(:get, "https://www.wixapis.com/ecom/v1/carts/cart_1")
        .to_return(status: 200, body: { cart: cart_response }.to_json)
      delete_stub = stub_request(:delete, "https://www.wixapis.com/ecom/v1/carts/cart_1")
                    .to_return(status: 200, body: "")

      cart = adapter.cancel_cart(cart_id: "cart_1", idempotency_key: "k1")

      expect(cart).to be_a(Portage::Ucp::Cart)
      expect(delete_stub).to have_been_requested
    end
  end

  describe "#create_checkout" do
    it "builds checkout line items from requested line items and returns status incomplete" do
      stub_request(:post, "https://www.wixapis.com/ecom/v1/checkouts")
        .to_return(status: 200, body: { checkout: cart_response.merge("id" => "checkout_1") }.to_json)

      checkout = adapter.create_checkout(line_items: [{ product_id: "var_1", quantity: 1 }],
                                         idempotency_key: "chk1")

      expect(checkout).to be_a(Portage::Ucp::Checkout)
      expect(checkout.status).to eq("incomplete")
      expect(checkout.id).to eq("checkout_1")
    end
  end

  describe "#get_checkout" do
    it "maps the underlying checkout to a Checkout with the last-tracked status" do
      stub_request(:post, "https://www.wixapis.com/ecom/v1/checkouts")
        .to_return(status: 200, body: { checkout: cart_response.merge("id" => "checkout_1") }.to_json)
      adapter.create_checkout(line_items: [{ product_id: "var_1", quantity: 1 }], idempotency_key: "chk1")
      stub_request(:get, "https://www.wixapis.com/ecom/v1/checkouts/checkout_1")
        .to_return(status: 200, body: { checkout: cart_response.merge("id" => "checkout_1") }.to_json)

      checkout = adapter.get_checkout(checkout_id: "checkout_1")

      expect(checkout.status).to eq("incomplete")
    end
  end

  describe "#cancel_checkout" do
    it "marks the tracked status canceled" do
      stub_request(:get, "https://www.wixapis.com/ecom/v1/checkouts/checkout_1")
        .to_return(status: 200, body: { checkout: cart_response.merge("id" => "checkout_1") }.to_json)

      checkout = adapter.cancel_checkout(checkout_id: "checkout_1", idempotency_key: "k1")

      expect(checkout.status).to eq("canceled")
    end
  end

  describe "#complete_checkout" do
    it "calls Wix's create-order endpoint, returning status completed when an orderId comes back" do
      stub_request(:get, "https://www.wixapis.com/ecom/v1/checkouts/checkout_1")
        .to_return(status: 200, body: { checkout: cart_response.merge("id" => "checkout_1") }.to_json)
      stub_request(:post, "https://www.wixapis.com/ecom/v1/checkouts/checkout_1/create-order")
        .to_return(status: 200, body: { orderId: "order_1" }.to_json)

      checkout = adapter.complete_checkout(checkout_id: "checkout_1", payment_token: "tok_abc123",
                                           idempotency_key: "chk1-complete")

      expect(checkout.status).to eq("completed")
    end

    it "raises when the checkout can't be found" do
      stub_request(:get, "https://www.wixapis.com/ecom/v1/checkouts/missing")
        .to_return(status: 200, body: { checkout: nil }.to_json)

      expect do
        adapter.complete_checkout(checkout_id: "missing", payment_token: "tok_abc123", idempotency_key: "k1")
      end.to raise_error(Portage::Ucp::Wix::Error, /checkout missing not found/)
    end
  end

  describe "#get_order" do
    it "queries the eCommerce Orders API and maps the result, reading checkout_id off the order itself" do
      stub_request(:get, "https://www.wixapis.com/ecom/v1/orders/order_1")
        .to_return(status: 200, body: { order: { id: "order_1", checkoutId: "checkout_1", currency: "USD",
                                                 priceSummary: { subtotal: { amount: "5.00" },
                                                                 total: { amount: "5.00" } },
                                                 lineItems: [] } }.to_json)

      order = adapter.get_order(order_id: "order_1")

      expect(order).to be_a(Portage::Ucp::Order)
      expect(order.checkout_id).to eq("checkout_1")
    end

    it "returns nil for an order the API doesn't find" do
      stub_request(:get, "https://www.wixapis.com/ecom/v1/orders/nonexistent")
        .to_return(status: 200, body: { order: nil }.to_json)

      expect(adapter.get_order(order_id: "nonexistent")).to be_nil
    end
  end
end
