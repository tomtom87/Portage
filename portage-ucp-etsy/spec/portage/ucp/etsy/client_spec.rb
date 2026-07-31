require "spec_helper"

RSpec.describe Portage::Ucp::Etsy::Client do
  let(:client) { described_class.new(access_token: "acc-tok", api_key: "keystring") }

  describe "#get" do
    it "sends both the bearer token and the x-api-key header" do
      stub = stub_request(:get, "https://api.etsy.com/v3/application/listings/1")
             .with(headers: { "Authorization" => "Bearer acc-tok", "x-api-key" => "keystring" })
             .to_return(status: 200, body: { listing_id: 1 }.to_json)

      result = client.get("/listings/1")

      expect(result).to eq({ "listing_id" => 1 })
      expect(stub).to have_been_requested
    end
  end

  it "raises ApiError for a non-2xx response" do
    stub_request(:get, "https://api.etsy.com/v3/application/listings/999")
      .to_return(status: 404, body: { error: "Listing not found" }.to_json)

    expect { client.get("/listings/999") }
      .to raise_error(Portage::Ucp::Etsy::ApiError, /Listing not found/)
  end
end
