require "spec_helper"

RSpec.describe Portage::Ucp::Magento::Client do
  let(:client) { described_class.new(base_url: "https://shop.example.com", admin_token: "admin-tok") }

  describe "#admin_get" do
    it "sends the admin token as a Bearer header" do
      stub = stub_request(:get, "https://shop.example.com/rest/V1/products/abc")
             .with(headers: { "Authorization" => "Bearer admin-tok" })
             .to_return(status: 200, body: { sku: "abc" }.to_json)

      result = client.admin_get("/products/abc")

      expect(result).to eq({ "sku" => "abc" })
      expect(stub).to have_been_requested
    end

    it "raises without an admin_token configured" do
      anonymous = described_class.new(base_url: "https://shop.example.com")

      expect { anonymous.admin_get("/products/abc") }.to raise_error(ArgumentError, /admin_token/)
    end
  end

  describe "#guest_post" do
    it "sends no Authorization header — guest-cart calls are anonymous" do
      stub = stub_request(:post, "https://shop.example.com/rest/V1/guest-carts")
             .with { |req| !req.headers.key?("Authorization") }
             .to_return(status: 200, body: '"cart_tok_1"')

      result = client.guest_post("/guest-carts")

      expect(result).to eq("cart_tok_1")
      expect(stub).to have_been_requested
    end
  end

  it "raises ApiError for a non-2xx response" do
    stub_request(:get, "https://shop.example.com/rest/V1/products/missing")
      .to_return(status: 404, body: { message: "no such entity" }.to_json)

    expect { client.admin_get("/products/missing") }
      .to raise_error(Portage::Ucp::Magento::ApiError, /no such entity/)
  end
end
