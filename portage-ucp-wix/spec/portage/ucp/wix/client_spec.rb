require "spec_helper"

RSpec.describe Portage::Ucp::Wix::Client do
  let(:client) { described_class.new(access_token: "site-token") }

  describe "#get" do
    it "sends the access token as the Authorization header" do
      stub = stub_request(:get, "https://www.wixapis.com/ecom/v1/carts/1")
             .with(headers: { "Authorization" => "site-token" })
             .to_return(status: 200, body: { cart: { id: "1" } }.to_json)

      result = client.get("/ecom/v1/carts/1")

      expect(result).to eq({ "cart" => { "id" => "1" } })
      expect(stub).to have_been_requested
    end
  end

  describe "#post" do
    it "sends a JSON body" do
      stub = stub_request(:post, "https://www.wixapis.com/ecom/v1/carts")
             .with(headers: { "Authorization" => "site-token", "Content-Type" => "application/json" },
                   body: { lineItems: [] }.to_json)
             .to_return(status: 200, body: { cart: { id: "1" } }.to_json)

      result = client.post("/ecom/v1/carts", { lineItems: [] })

      expect(result).to eq({ "cart" => { "id" => "1" } })
      expect(stub).to have_been_requested
    end
  end

  describe "#patch" do
    it "sends a PATCH request" do
      stub_request(:patch, "https://www.wixapis.com/ecom/v1/checkouts/1")
        .to_return(status: 200, body: { checkout: { id: "1" } }.to_json)

      expect(client.patch("/ecom/v1/checkouts/1", { lineItems: [] })).to eq({ "checkout" => { "id" => "1" } })
    end
  end

  describe "#delete" do
    it "sends a DELETE request and tolerates an empty body" do
      stub_request(:delete, "https://www.wixapis.com/ecom/v1/carts/1").to_return(status: 200, body: "")

      expect(client.delete("/ecom/v1/carts/1")).to eq({})
    end
  end

  it "raises ApiError for a non-2xx response" do
    stub_request(:get, "https://www.wixapis.com/ecom/v1/carts/1")
      .to_return(status: 404, body: { message: "cart not found" }.to_json)

    expect { client.get("/ecom/v1/carts/1") }
      .to raise_error(Portage::Ucp::Wix::ApiError, /cart not found/)
  end
end
