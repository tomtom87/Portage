require "spec_helper"

RSpec.describe Portage::Ucp::BigCommerce::Adapter do
  let(:client) do
    Portage::Ucp::BigCommerce::Client.new(store_hash: "abc123", client_id: "client_1", access_token: "token_1")
  end
  let(:adapter) do
    described_class.new(client: client, site_url: "https://shop.example.com", currency: "USD",
                        payment_gateway_id: "stripe")
  end

  let(:cart_response) do
    { "id" => "cart_1", "currency" => { "code" => "USD" }, "base_amount" => 5.0, "cart_amount" => 5.0,
      "line_items" => { "physical_items" => [
        { "id" => "item_1", "product_id" => 1, "name" => "Cold Brew", "quantity" => 1,
          "sale_price" => 5.0, "extended_sale_price" => 5.0, "extended_list_price" => 5.0 }
      ] } }
  end

  let(:empty_cart_response) { cart_response.merge("line_items" => {}) }

  let(:checkout_response) { { "cart" => cart_response, "subtotal" => 5.0, "tax_total" => 0.0, "grand_total" => 5.0 } }

  def stub_cart_get(body = cart_response)
    stub_request(:get, %r{https://api\.bigcommerce\.com/stores/abc123/v3/carts/cart_1})
      .to_return(status: 200, body: { data: body }.to_json)
  end

  def stub_checkout_get(body = checkout_response)
    stub_request(:get, "https://api.bigcommerce.com/stores/abc123/v3/checkouts/cart_1")
      .to_return(status: 200, body: { data: body }.to_json)
  end

  describe "capability advertisement (§2.1)" do
    it "only advertises capabilities backed by an overridden method — no BigCommerce identity linking" do
      registry = Portage::Ucp::CapabilityRegistry.default
      advertised_names = registry.advertised(adapter).map(&:name)

      expect(advertised_names).to include("dev.ucp.shopping.catalog", "dev.ucp.shopping.cart",
                                          "dev.ucp.shopping.checkout", "dev.ucp.shopping.order")
      expect(advertised_names).not_to include("dev.ucp.shopping.identity")
    end
  end

  describe "#search_catalog" do
    it "queries the v3 Catalog products endpoint and maps results to Portage::Ucp::Product" do
      stub_request(:get, "https://api.bigcommerce.com/stores/abc123/v3/catalog/products?keyword=brew&limit=10&include=variants")
        .to_return(status: 200, body: { data: [{ id: 1, name: "Cold Brew", price: 5.0,
                                                 availability: "available" }] }.to_json)

      products = adapter.search_catalog(query: "brew", limit: 10)

      expect(products.first).to be_a(Portage::Ucp::Product)
      expect(products.first.title).to eq("Cold Brew")
    end
  end

  describe "#get_product" do
    it "fetches a product with its variants included" do
      stub_request(:get, "https://api.bigcommerce.com/stores/abc123/v3/catalog/products/1?include=variants")
        .to_return(status: 200, body: { data: { id: 1, name: "Cold Brew", price: 5.0,
                                                availability: "available" } }.to_json)

      product = adapter.get_product(product_id: 1)

      expect(product.id).to eq("1")
    end

    it "returns nil for a product the API doesn't find" do
      stub_request(:get, "https://api.bigcommerce.com/stores/abc123/v3/catalog/products/999?include=variants")
        .to_return(status: 404, body: { title: "Not Found" }.to_json)

      expect(adapter.get_product(product_id: 999)).to be_nil
    end
  end

  describe "#get_cart" do
    it "queries the v3 Carts endpoint and maps the result to a Portage::Ucp::Cart" do
      stub_cart_get

      cart = adapter.get_cart(cart_id: "cart_1")

      expect(cart.line_items.size).to eq(1)
      expect(cart.totals.find { |t| t.type == "total" }.amount).to eq(500)
    end
  end

  describe "#create_cart" do
    it "posts the requested line items and dedups by idempotency_key (§9a)" do
      create_stub = stub_request(:post, "https://api.bigcommerce.com/stores/abc123/v3/carts")
                    .with(body: { line_items: [{ product_id: 1, quantity: 1 }] }.to_json)
                    .to_return(status: 200, body: { data: cart_response }.to_json)

      first = adapter.create_cart(line_items: [{ product_id: 1, quantity: 1 }], idempotency_key: "dupe")
      second = adapter.create_cart(line_items: [{ product_id: 1, quantity: 1 }], idempotency_key: "dupe")

      expect(first).to be_a(Portage::Ucp::Cart)
      expect(second).to equal(first)
      expect(create_stub).to have_been_requested.once
    end
  end

  describe "#update_cart" do
    it "adds the desired lines before removing the old ones, to avoid auto-deleting the cart" do
      stub_cart_get(cart_response)
      add_stub = stub_request(:post, "https://api.bigcommerce.com/stores/abc123/v3/carts/cart_1/items")
                 .to_return(status: 200, body: { data: cart_response }.to_json)
      remove_stub = stub_request(:delete, "https://api.bigcommerce.com/stores/abc123/v3/carts/cart_1/items/item_1")
                    .to_return(status: 200, body: { data: cart_response }.to_json)

      cart = adapter.update_cart(cart_id: "cart_1", line_items: [{ product_id: 2, quantity: 1 }],
                                 idempotency_key: "k1")

      expect(cart).to be_a(Portage::Ucp::Cart)
      expect(add_stub).to have_been_requested
      expect(remove_stub).to have_been_requested
    end
  end

  describe "#cancel_cart" do
    it "deletes the cart resource outright" do
      delete_stub = stub_request(:delete, "https://api.bigcommerce.com/stores/abc123/v3/carts/cart_1")
                    .to_return(status: 204, body: "")

      cart = adapter.cancel_cart(cart_id: "cart_1", idempotency_key: "k1")

      expect(cart.line_items).to eq([])
      expect(delete_stub).to have_been_requested
    end
  end

  describe "#create_checkout" do
    it "creates a cart then fetches its matching checkout, returning status incomplete" do
      stub_request(:post, "https://api.bigcommerce.com/stores/abc123/v3/carts")
        .to_return(status: 200, body: { data: cart_response }.to_json)
      stub_checkout_get

      checkout = adapter.create_checkout(line_items: [{ product_id: 1, quantity: 1 }], idempotency_key: "chk1")

      expect(checkout).to be_a(Portage::Ucp::Checkout)
      expect(checkout.status).to eq("incomplete")
    end
  end

  describe "#cancel_checkout" do
    it "marks the tracked status canceled without touching the cart" do
      stub_checkout_get

      checkout = adapter.cancel_checkout(checkout_id: "cart_1", idempotency_key: "k1")

      expect(checkout.status).to eq("canceled")
    end
  end

  describe "#complete_checkout" do
    it "creates an order, mints a payment access token, then submits payment to the Payments API" do
      stub_checkout_get
      order_stub = stub_request(:post, "https://api.bigcommerce.com/stores/abc123/v3/checkouts/cart_1/orders")
                   .to_return(status: 200, body: { data: { id: 99 } }.to_json)
      token_stub = stub_request(:post, "https://api.bigcommerce.com/stores/abc123/v3/payments/access_tokens")
                   .with(body: { order: { id: 99 } }.to_json)
                   .to_return(status: 200, body: { data: { id: "pat_1" } }.to_json)
      payment_stub = stub_request(:post, "https://payments.bigcommerce.com/stores/abc123/payments")
                     .with(headers: { "Authorization" => "pat_1" })
                     .to_return(status: 200, body: { id: "payment_1" }.to_json)

      checkout = adapter.complete_checkout(checkout_id: "cart_1", payment_token: "tok_abc123",
                                           idempotency_key: "chk1-complete")

      expect(checkout.status).to eq("completed")
      expect(order_stub).to have_been_requested
      expect(token_stub).to have_been_requested
      expect(payment_stub).to have_been_requested
    end

    it "raises when no payment_gateway_id is configured on the Adapter" do
      bare_adapter = described_class.new(client: client, site_url: "https://shop.example.com", currency: "USD")

      expect do
        bare_adapter.complete_checkout(checkout_id: "cart_1", payment_token: "tok_abc123", idempotency_key: "k1")
      end.to raise_error(Portage::Ucp::BigCommerce::Error, /no payment_gateway_id configured/)
    end
  end

  describe "#get_order" do
    it "queries the v2 Orders endpoint plus its products, threading through a checkout_id recorded at completion" do
      stub_checkout_get
      stub_request(:post, "https://api.bigcommerce.com/stores/abc123/v3/checkouts/cart_1/orders")
        .to_return(status: 200, body: { data: { id: 99 } }.to_json)
      stub_request(:post, "https://api.bigcommerce.com/stores/abc123/v3/payments/access_tokens")
        .to_return(status: 200, body: { data: { id: "pat_1" } }.to_json)
      stub_request(:post, "https://payments.bigcommerce.com/stores/abc123/payments")
        .to_return(status: 200, body: { id: "payment_1" }.to_json)
      adapter.complete_checkout(checkout_id: "cart_1", payment_token: "tok_abc123", idempotency_key: "chk1-link")

      stub_request(:get, "https://api.bigcommerce.com/stores/abc123/v2/orders/99")
        .to_return(status: 200, body: { id: 99, currency_code: "USD", status_id: 11, subtotal_ex_tax: "5.00",
                                        total_inc_tax: "5.00" }.to_json)
      stub_request(:get, "https://api.bigcommerce.com/stores/abc123/v2/orders/99/products")
        .to_return(status: 200, body: [].to_json)

      order = adapter.get_order(order_id: 99)

      expect(order).to be_a(Portage::Ucp::Order)
      expect(order.checkout_id).to eq("cart_1")
    end

    it "returns nil for an order the API doesn't find" do
      stub_request(:get, "https://api.bigcommerce.com/stores/abc123/v2/orders/999")
        .to_return(status: 404, body: { errors: { id: "Not found" } }.to_json)

      expect(adapter.get_order(order_id: 999)).to be_nil
    end
  end
end
