require "spec_helper"

RSpec.describe Portage::Ucp::Magento::Adapter do
  let(:client) { Portage::Ucp::Magento::Client.new(base_url: "https://shop.example.com", admin_token: "admin-tok") }
  let(:default_address) do
    { firstname: "Ada", lastname: "Lovelace", street: ["1 Main St"], city: "Boston", region: "MA",
      postcode: "02110", country_id: "US", telephone: "555-0100", email: "ada@example.com" }
  end
  let(:adapter) do
    described_class.new(client: client, currency: "USD", site_url: "https://shop.example.com",
                        payment_method: "checkmo", default_address: default_address)
  end

  let(:cart_items) { [{ "item_id" => 1, "sku" => "cold-brew", "name" => "Cold Brew", "qty" => 1, "price" => 5.0 }] }
  let(:cart_totals) do
    { "quote_currency_code" => "USD",
      "items" => [{ "item_id" => 1, "row_total" => "5.0000", "tax_amount" => "0.0000" }] }
  end

  def stub_cart(cart_id, items: cart_items, totals: cart_totals)
    stub_request(:get, "https://shop.example.com/rest/V1/guest-carts/#{cart_id}/items")
      .to_return(status: 200, body: items.to_json)
    stub_request(:get, "https://shop.example.com/rest/V1/guest-carts/#{cart_id}/totals")
      .to_return(status: 200, body: totals.to_json)
  end

  describe "capability advertisement (§2.1)" do
    it "only advertises capabilities backed by an overridden method — no Magento identity linking" do
      registry = Portage::Ucp::CapabilityRegistry.default
      advertised_names = registry.advertised(adapter).map(&:name)

      expect(advertised_names).to include("dev.ucp.shopping.catalog", "dev.ucp.shopping.cart",
                                          "dev.ucp.shopping.checkout", "dev.ucp.shopping.order")
      expect(advertised_names).not_to include("dev.ucp.shopping.identity")
    end
  end

  describe "#search_catalog" do
    it "builds a searchCriteria query and maps results to Portage::Ucp::Product" do
      stub_request(:get, %r{/rest/V1/products\?})
        .to_return(status: 200, body: { items: [{ sku: "cold-brew", name: "Cold Brew", price: 5.0,
                                                  status: 1 }] }.to_json)

      products = adapter.search_catalog(query: "brew", limit: 10)

      expect(products.first).to be_a(Portage::Ucp::Product)
      expect(products.first.title).to eq("Cold Brew")
    end
  end

  describe "#get_product" do
    it "fetches configurable children before mapping" do
      stub_request(:get, "https://shop.example.com/rest/V1/products/cold-brew")
        .to_return(status: 200, body: { sku: "cold-brew", name: "Cold Brew", price: 5.0, status: 1,
                                        type_id: "configurable" }.to_json)
      stub_request(:get, "https://shop.example.com/rest/V1/configurable-products/cold-brew/children")
        .to_return(status: 200, body: [{ sku: "cold-brew-large", name: "Large", price: 6.0, status: 1 }].to_json)

      product = adapter.get_product(product_id: "cold-brew")

      expect(product.variants.first[:id]).to eq("cold-brew-large")
    end

    it "returns nil for a product the API doesn't find" do
      stub_request(:get, "https://shop.example.com/rest/V1/products/missing")
        .to_return(status: 404, body: { message: "no such entity" }.to_json)

      expect(adapter.get_product(product_id: "missing")).to be_nil
    end
  end

  describe "#get_cart" do
    it "merges guest-cart items and totals into a Portage::Ucp::Cart" do
      stub_cart("cart_1")

      cart = adapter.get_cart(cart_id: "cart_1")

      expect(cart.line_items.size).to eq(1)
      expect(cart.totals.find { |t| t.type == "total" }.amount).to eq(500)
    end
  end

  describe "#create_cart" do
    it "creates a guest cart, adds each line item by sku, and dedups by idempotency_key (§9a)" do
      create_stub = stub_request(:post, "https://shop.example.com/rest/V1/guest-carts")
                    .to_return(status: 200, body: '"cart_1"')
      add_stub = stub_request(:post, "https://shop.example.com/rest/V1/guest-carts/cart_1/items")
                 .with(body: { cartItem: { sku: "cold-brew", qty: 1, quote_id: "cart_1" } }.to_json)
                 .to_return(status: 200, body: { item_id: 1 }.to_json)
      stub_cart("cart_1")

      first = adapter.create_cart(line_items: [{ product_id: "cold-brew", quantity: 1 }], idempotency_key: "dupe")
      second = adapter.create_cart(line_items: [{ product_id: "cold-brew", quantity: 1 }], idempotency_key: "dupe")

      expect(first).to be_a(Portage::Ucp::Cart)
      expect(second).to equal(first)
      expect(create_stub).to have_been_requested.once
      expect(add_stub).to have_been_requested.once
    end
  end

  describe "#update_cart" do
    it "replaces all lines by removing the current ones then adding the desired ones" do
      stub_request(:get, "https://shop.example.com/rest/V1/guest-carts/cart_1/items")
        .to_return(status: 200, body: cart_items.to_json)
      remove_stub = stub_request(:delete, "https://shop.example.com/rest/V1/guest-carts/cart_1/items/1")
                    .to_return(status: 200, body: "true")
      add_stub = stub_request(:post, "https://shop.example.com/rest/V1/guest-carts/cart_1/items")
                 .to_return(status: 200, body: { item_id: 2 }.to_json)
      stub_request(:get, "https://shop.example.com/rest/V1/guest-carts/cart_1/totals")
        .to_return(status: 200, body: cart_totals.to_json)

      cart = adapter.update_cart(cart_id: "cart_1", line_items: [{ product_id: "cold-brew", quantity: 2 }],
                                 idempotency_key: "k1")

      expect(cart).to be_a(Portage::Ucp::Cart)
      expect(remove_stub).to have_been_requested
      expect(add_stub).to have_been_requested
    end
  end

  describe "#cancel_cart" do
    it "clears every line, the closest real equivalent to cancellation" do
      stub_request(:get, "https://shop.example.com/rest/V1/guest-carts/cart_1/items")
        .to_return(status: 200, body: cart_items.to_json)
      remove_stub = stub_request(:delete, "https://shop.example.com/rest/V1/guest-carts/cart_1/items/1")
                    .to_return(status: 200, body: "true")
      stub_request(:get, "https://shop.example.com/rest/V1/guest-carts/cart_1/totals")
        .to_return(status: 200, body: { "quote_currency_code" => "USD", "items" => [] }.to_json)

      cart = adapter.cancel_cart(cart_id: "cart_1", idempotency_key: "k1")

      expect(cart).to be_a(Portage::Ucp::Cart)
      expect(remove_stub).to have_been_requested
    end
  end

  describe "#create_checkout" do
    it "builds a guest cart from requested line items and returns status incomplete" do
      stub_request(:post, "https://shop.example.com/rest/V1/guest-carts").to_return(status: 200, body: '"cart_1"')
      stub_request(:post, "https://shop.example.com/rest/V1/guest-carts/cart_1/items")
        .to_return(status: 200, body: { item_id: 1 }.to_json)
      stub_cart("cart_1")

      checkout = adapter.create_checkout(line_items: [{ product_id: "cold-brew", quantity: 1 }],
                                         idempotency_key: "chk1")

      expect(checkout).to be_a(Portage::Ucp::Checkout)
      expect(checkout.status).to eq("incomplete")
      expect(checkout.id).to eq("cart_1")
    end
  end

  describe "#cancel_checkout" do
    it "marks the tracked status canceled without touching cart contents" do
      stub_cart("cart_1")

      checkout = adapter.cancel_checkout(checkout_id: "cart_1", idempotency_key: "k1")

      expect(checkout.status).to eq("canceled")
    end
  end

  describe "#complete_checkout" do
    it "posts shipping-information then payment-information, returning status completed" do
      stub_cart("cart_1")
      shipping_stub = stub_request(:post, "https://shop.example.com/rest/V1/guest-carts/cart_1/shipping-information")
                      .to_return(status: 200, body: { totals: {} }.to_json)
      payment_stub = stub_request(:post, "https://shop.example.com/rest/V1/guest-carts/cart_1/payment-information")
                     .with(body: hash_including(
                       "paymentMethod" => { "method" => "checkmo", "additional_data" => { "cc_token" => "tok_abc" } }
                     ))
                     .to_return(status: 200, body: "99")

      checkout = adapter.complete_checkout(checkout_id: "cart_1", payment_token: "tok_abc",
                                           idempotency_key: "chk1-complete")

      expect(checkout.status).to eq("completed")
      expect(shipping_stub).to have_been_requested
      expect(payment_stub).to have_been_requested
    end

    it "raises when no payment_method is configured on the Adapter" do
      bare_adapter = described_class.new(client: client, currency: "USD", default_address: default_address)

      expect do
        bare_adapter.complete_checkout(checkout_id: "cart_1", payment_token: "tok_abc", idempotency_key: "k1")
      end.to raise_error(Portage::Ucp::Magento::Error, /no payment_method configured/)
    end

    it "raises when no default_address is configured on the Adapter" do
      bare_adapter = described_class.new(client: client, currency: "USD", payment_method: "checkmo")

      expect do
        bare_adapter.complete_checkout(checkout_id: "cart_1", payment_token: "tok_abc", idempotency_key: "k1")
      end.to raise_error(Portage::Ucp::Magento::Error, /no default_address configured/)
    end
  end

  describe "#get_order" do
    it "queries the admin orders endpoint, threading through a checkout_id recorded at completion" do
      stub_cart("cart_1")
      stub_request(:post, "https://shop.example.com/rest/V1/guest-carts/cart_1/shipping-information")
        .to_return(status: 200, body: { totals: {} }.to_json)
      stub_request(:post, "https://shop.example.com/rest/V1/guest-carts/cart_1/payment-information")
        .to_return(status: 200, body: "99")
      adapter.complete_checkout(checkout_id: "cart_1", payment_token: "tok_abc", idempotency_key: "chk1-link")

      stub_request(:get, "https://shop.example.com/rest/V1/orders/99")
        .to_return(status: 200, body: { entity_id: 99, order_currency_code: "USD", status: "processing",
                                        subtotal: "5.0000", grand_total: "5.0000", items: [] }.to_json)

      order = adapter.get_order(order_id: 99)

      expect(order).to be_a(Portage::Ucp::Order)
      expect(order.checkout_id).to eq("cart_1")
    end

    it "returns nil for an order the API doesn't find" do
      stub_request(:get, "https://shop.example.com/rest/V1/orders/999")
        .to_return(status: 404, body: { message: "no such entity" }.to_json)

      expect(adapter.get_order(order_id: 999)).to be_nil
    end
  end
end
