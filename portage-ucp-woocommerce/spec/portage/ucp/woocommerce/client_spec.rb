require "spec_helper"
require "base64"

RSpec.describe Portage::Ucp::WooCommerce::Client do
  let(:client) do
    described_class.new(site_url: "https://shop.example.com", consumer_key: "ck_abc", consumer_secret: "cs_xyz")
  end

  describe "#admin_get" do
    it "sends Basic Auth with the consumer key/secret" do
      credentials = Base64.strict_encode64("ck_abc:cs_xyz")
      stub = stub_request(:get, "https://shop.example.com/wp-json/wc/v3/products")
             .with(headers: { "Authorization" => "Basic #{credentials}" })
             .to_return(status: 200, body: [{ id: 1, name: "Cold Brew" }].to_json)

      result = client.admin_get("/products")

      expect(result).to eq([{ "id" => 1, "name" => "Cold Brew" }])
      expect(stub).to have_been_requested
    end
  end

  describe "#store_get / #store_post" do
    it "has no Cart-Token to send on the first call, then threads it on subsequent calls" do
      first = stub_request(:get, "https://shop.example.com/wp-json/wc/store/v1/cart")
              .to_return(status: 200, body: { items: [] }.to_json, headers: { "Cart-Token" => "tok_1",
                                                                              "Nonce" => "nonce_1" })

      client.store_get("/cart")

      expect(first).to have_been_requested
      expect(client.cart_token).to eq("tok_1")

      second = stub_request(:post, "https://shop.example.com/wp-json/wc/store/v1/cart/add-item")
               .with(headers: { "Cart-Token" => "tok_1", "Nonce" => "nonce_1" })
               .to_return(status: 200, body: { items: [] }.to_json)

      client.store_post("/cart/add-item", { id: 1, quantity: 1 })

      expect(second).to have_been_requested
    end

    it "does not send a Nonce header on GET requests, even once one's been seen" do
      stub_request(:get, "https://shop.example.com/wp-json/wc/store/v1/cart")
        .to_return(status: 200, body: { items: [] }.to_json, headers: { "Nonce" => "nonce_1" })
      client.store_get("/cart")
      client.store_get("/cart")

      expect(a_request(:get, "https://shop.example.com/wp-json/wc/store/v1/cart")
        .with { |req| !req.headers.key?("Nonce") }).to have_been_made.times(2)
    end
  end

  it "raises ApiError for a non-2xx response" do
    stub_request(:get, "https://shop.example.com/wp-json/wc/v3/products/999")
      .to_return(status: 404, body: { code: "woocommerce_rest_product_invalid_id", message: "Invalid ID" }.to_json)

    expect { client.admin_get("/products/999") }
      .to raise_error(Portage::Ucp::WooCommerce::ApiError, /Invalid ID/)
  end
end
