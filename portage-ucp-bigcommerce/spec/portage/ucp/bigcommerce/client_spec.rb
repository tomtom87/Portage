require "spec_helper"

RSpec.describe Portage::Ucp::BigCommerce::Client do
  let(:client) do
    described_class.new(store_hash: "abc123", client_id: "client_1", access_token: "token_1")
  end

  describe "#v3_get" do
    it "sends X-Auth-Client/X-Auth-Token headers against the v3 host" do
      stub = stub_request(:get, "https://api.bigcommerce.com/stores/abc123/v3/catalog/products")
             .with(headers: { "X-Auth-Client" => "client_1", "X-Auth-Token" => "token_1" })
             .to_return(status: 200, body: { data: [{ id: 1, name: "Cold Brew" }] }.to_json)

      result = client.v3_get("/catalog/products")

      expect(result).to eq({ "data" => [{ "id" => 1, "name" => "Cold Brew" }] })
      expect(stub).to have_been_requested
    end
  end

  describe "#v2_get" do
    it "requests against the v2 host with the same credentials" do
      stub = stub_request(:get, "https://api.bigcommerce.com/stores/abc123/v2/orders/1")
             .with(headers: { "X-Auth-Client" => "client_1", "X-Auth-Token" => "token_1" })
             .to_return(status: 200, body: { id: 1 }.to_json)

      expect(client.v2_get("/orders/1")).to eq({ "id" => 1 })
      expect(stub).to have_been_requested
    end
  end

  describe "#process_payment" do
    it "authorizes with the payment access token against the payments host, not the store credentials" do
      stub = stub_request(:post, "https://payments.bigcommerce.com/stores/abc123/payments")
             .with(headers: { "Authorization" => "pat_1" },
                   body: { payment: { instrument: { type: "tokenized_instrument", token: "tok_1" } },
                           order: { id: 99 } }.to_json)
             .to_return(status: 200, body: { id: "payment_1" }.to_json)

      result = client.process_payment(payment_access_token: "pat_1", order_id: 99,
                                      payment_instrument: { type: "tokenized_instrument", token: "tok_1" })

      expect(result).to eq({ "id" => "payment_1" })
      expect(stub).to have_been_requested
    end
  end

  it "raises ApiError for a non-2xx response" do
    stub_request(:get, "https://api.bigcommerce.com/stores/abc123/v3/catalog/products/999")
      .to_return(status: 404, body: { title: "Not Found" }.to_json)

    expect { client.v3_get("/catalog/products/999") }
      .to raise_error(Portage::Ucp::BigCommerce::ApiError, /Not Found/)
  end
end
