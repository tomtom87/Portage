require "spec_helper"

RSpec.describe Portage::Ucp::Instagram::Client do
  let(:client) { described_class.new(access_token: "acc-tok") }

  describe "#get" do
    it "sends the access token as a Bearer header against the default api version" do
      stub = stub_request(:get, "https://graph.facebook.com/v21.0/123")
             .with(headers: { "Authorization" => "Bearer acc-tok" })
             .to_return(status: 200, body: { id: "123" }.to_json)

      result = client.get("/123")

      expect(result).to eq({ "id" => "123" })
      expect(stub).to have_been_requested
    end
  end

  it "raises ApiError for a non-2xx response" do
    stub_request(:get, "https://graph.facebook.com/v21.0/missing")
      .to_return(status: 404, body: { error: { message: "Unsupported get request" } }.to_json)

    expect { client.get("/missing") }
      .to raise_error(Portage::Ucp::Instagram::ApiError, /Unsupported get request/)
  end
end
