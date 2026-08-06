require "spec_helper"

RSpec.describe Portage::Ucp::WooCommerce::Adapter do
  let(:client) do
    Portage::Ucp::WooCommerce::Client.new(site_url: "https://shop.example.com", consumer_key: "ck",
                                          consumer_secret: "cs")
  end
  let(:adapter) do
    described_class.new(client: client, site_url: "https://shop.example.com", currency: "USD",
                        payment_method: "stripe_cc")
  end

  let(:cart_response) do
    { "items" => [{ "key" => "line_1", "id" => 1, "name" => "Cold Brew", "quantity" => 1,
                    "prices" => { "price" => "500" } }],
      "totals" => { "currency_code" => "USD", "total_items" => "500", "total_tax" => "0",
                    "total_price" => "500" } }
  end

  let(:empty_cart_response) { cart_response.merge("items" => []) }

  def stub_cart_get(body = cart_response, headers: {})
    stub_request(:get, "https://shop.example.com/wp-json/wc/store/v1/cart")
      .to_return(status: 200, body: body.to_json, headers: { "Cart-Token" => "tok_1" }.merge(headers))
  end

  describe "capability advertisement (§2.1)" do
    it "only advertises capabilities backed by an overridden method — no WooCommerce identity linking" do
      registry = Portage::Ucp::CapabilityRegistry.default
      advertised_names = registry.advertised(adapter).map(&:name)

      expect(advertised_names).to include("dev.ucp.shopping.catalog", "dev.ucp.shopping.cart",
                                          "dev.ucp.shopping.checkout", "dev.ucp.shopping.order")
      expect(advertised_names).not_to include("dev.ucp.shopping.identity")
    end
  end

  describe "#search_catalog" do
    it "queries the Admin products endpoint and maps results to Portage::Ucp::Product" do
      stub_request(:get, "https://shop.example.com/wp-json/wc/v3/products?search=brew&per_page=10")
        .to_return(status: 200, body: [{ id: 1, name: "Cold Brew", price: "5.00", stock_status: "instock",
                                         type: "simple" }].to_json)

      products = adapter.search_catalog(query: "brew", limit: 10)

      expect(products.first).to be_a(Portage::Ucp::Product)
      expect(products.first.title).to eq("Cold Brew")
    end
  end

  describe "#get_product" do
    it "fetches variations for a variable product before mapping" do
      stub_request(:get, "https://shop.example.com/wp-json/wc/v3/products/1")
        .to_return(status: 200, body: { id: 1, name: "Cold Brew", price: "5.00", stock_status: "instock",
                                        type: "variable", variations: [2] }.to_json)
      stub_request(:get, "https://shop.example.com/wp-json/wc/v3/products/1/variations?per_page=100")
        .to_return(status: 200, body: [{ id: 2, price: "6.00", stock_status: "instock", attributes: [] }].to_json)

      product = adapter.get_product(product_id: 1)

      expect(product.variants.first[:id]).to eq("2")
    end

    it "returns nil for a product the API doesn't find" do
      stub_request(:get, "https://shop.example.com/wp-json/wc/v3/products/999")
        .to_return(status: 404, body: { code: "woocommerce_rest_product_invalid_id", message: "Invalid ID" }.to_json)

      expect(adapter.get_product(product_id: 999)).to be_nil
    end
  end

  describe "#get_cart" do
    it "queries the Store API cart and maps the result to a Portage::Ucp::Cart" do
      stub_cart_get

      cart = adapter.get_cart(cart_id: "tok_1")

      expect(cart.line_items.size).to eq(1)
      expect(cart.totals.find { |t| t.type == "total" }.amount).to eq(500)
    end
  end

  describe "#create_cart" do
    it "adds each requested line item and dedups by idempotency_key (§9a)" do
      stub_cart_get(empty_cart_response)
      add_stub = stub_request(:post, "https://shop.example.com/wp-json/wc/store/v1/cart/add-item")
                 .with(body: { id: 1, quantity: 1 }.to_json)
                 .to_return(status: 200, body: cart_response.to_json)

      first = adapter.create_cart(line_items: [{ product_id: 1, quantity: 1 }], idempotency_key: "dupe")
      second = adapter.create_cart(line_items: [{ product_id: 1, quantity: 1 }], idempotency_key: "dupe")

      expect(first).to be_a(Portage::Ucp::Cart)
      expect(second).to equal(first)
      expect(add_stub).to have_been_requested.once
    end
  end

  describe "#update_cart" do
    it "replaces all lines by removing the current ones then adding the desired ones" do
      stub_cart_get(cart_response)
      remove_stub = stub_request(:post, "https://shop.example.com/wp-json/wc/store/v1/cart/remove-item")
                    .with(body: { key: "line_1" }.to_json)
                    .to_return(status: 200, body: empty_cart_response.to_json)
      add_stub = stub_request(:post, "https://shop.example.com/wp-json/wc/store/v1/cart/add-item")
                 .to_return(status: 200, body: cart_response.to_json)

      cart = adapter.update_cart(cart_id: "tok_1", line_items: [{ product_id: 1, quantity: 1 }],
                                 idempotency_key: "k1")

      expect(cart).to be_a(Portage::Ucp::Cart)
      expect(remove_stub).to have_been_requested
      expect(add_stub).to have_been_requested
    end
  end

  describe "#cancel_cart" do
    it "clears every line, the closest real equivalent to cancellation" do
      stub_request(:get, "https://shop.example.com/wp-json/wc/store/v1/cart")
        .to_return({ status: 200, body: cart_response.to_json, headers: { "Cart-Token" => "tok_1" } },
                   { status: 200, body: empty_cart_response.to_json, headers: { "Cart-Token" => "tok_1" } })
      remove_stub = stub_request(:post, "https://shop.example.com/wp-json/wc/store/v1/cart/remove-item")
                    .to_return(status: 200, body: empty_cart_response.to_json)

      cart = adapter.cancel_cart(cart_id: "tok_1", idempotency_key: "k1")

      expect(cart.line_items).to eq([])
      expect(remove_stub).to have_been_requested
    end
  end

  describe "#create_checkout" do
    it "builds cart lines from requested line items and returns status incomplete" do
      stub_cart_get(empty_cart_response)
      stub_request(:post, "https://shop.example.com/wp-json/wc/store/v1/cart/add-item")
        .to_return(status: 200, body: cart_response.to_json)

      checkout = adapter.create_checkout(line_items: [{ product_id: 1, quantity: 1 }], idempotency_key: "chk1")

      expect(checkout).to be_a(Portage::Ucp::Checkout)
      expect(checkout.status).to eq("incomplete")
    end
  end

  describe "#cancel_checkout" do
    it "marks the tracked status canceled without touching cart contents" do
      stub_cart_get(cart_response)

      checkout = adapter.cancel_checkout(checkout_id: "tok_1", idempotency_key: "k1")

      expect(checkout.status).to eq("canceled")
    end
  end

  describe "#complete_checkout" do
    it "posts payment_method/payment_data to the Store API checkout endpoint" do
      stub = stub_request(:post, "https://shop.example.com/wp-json/wc/store/v1/checkout")
             .with(body: { payment_method: "stripe_cc",
                           payment_data: [{ key: "token", value: "tok_abc123" }] }.to_json)
             .to_return(status: 200, body: cart_response.merge("order_id" => 99, "order_key" => "wc_order_x").to_json)

      checkout = adapter.complete_checkout(checkout_id: "tok_1", payment_token: "tok_abc123",
                                           idempotency_key: "chk1-complete")

      expect(checkout.status).to eq("completed")
      expect(checkout.order).to eq(
        Portage::Ucp::OrderConfirmation.new(
          id: "99", permalink_url: "https://shop.example.com/checkout/order-received/99/?key=wc_order_x"
        )
      )
      expect(stub).to have_been_requested
    end

    it "raises when no payment_method is configured on the Adapter" do
      bare_adapter = described_class.new(client: client, site_url: "https://shop.example.com", currency: "USD")

      expect do
        bare_adapter.complete_checkout(checkout_id: "tok_1", payment_token: "tok_abc123", idempotency_key: "k1")
      end.to raise_error(Portage::Ucp::WooCommerce::Error, /no payment_method configured/)
    end
  end

  describe "#get_order" do
    it "queries the Admin orders endpoint, threading through a checkout_id recorded at completion" do
      stub_request(:post, "https://shop.example.com/wp-json/wc/store/v1/checkout")
        .to_return(status: 200, body: cart_response.merge("order_id" => 99).to_json)
      adapter.complete_checkout(checkout_id: "tok_1", payment_token: "tok_abc123", idempotency_key: "chk1-link")

      stub_request(:get, "https://shop.example.com/wp-json/wc/v3/orders/99")
        .to_return(status: 200, body: { id: 99, order_key: "wc_order_x", currency: "USD", status: "processing",
                                        total: "5.00", total_tax: "0.00", line_items: [] }.to_json)

      order = adapter.get_order(order_id: 99)

      expect(order).to be_a(Portage::Ucp::Order)
      expect(order.checkout_id).to eq("tok_1")
    end

    it "returns nil for an order the API doesn't find" do
      stub_request(:get, "https://shop.example.com/wp-json/wc/v3/orders/999")
        .to_return(status: 404, body: { code: "woocommerce_rest_shop_order_invalid_id",
                                        message: "Invalid ID" }.to_json)

      expect(adapter.get_order(order_id: 999)).to be_nil
    end
  end
end
