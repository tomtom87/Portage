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

    it "fetches an absolute URL as-is, without re-prefixing the base/api version" do
      stub = stub_request(:get, "https://graph.facebook.com/v21.0/123?after=cursor1")
             .to_return(status: 200, body: { id: "123" }.to_json)

      result = client.get("https://graph.facebook.com/v21.0/123?after=cursor1")

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

  it "exposes Meta's own error code/error_subcode/fbtrace_id on ApiError" do
    stub_request(:get, "https://graph.facebook.com/v21.0/missing")
      .to_return(status: 400, body: { error: { message: "bad request", code: 100, error_subcode: 33,
                                               fbtrace_id: "Abc123" } }.to_json)

    expect { client.get("/missing") }.to raise_error(Portage::Ucp::Instagram::ApiError) do |e|
      expect(e.code).to eq(100)
      expect(e.error_subcode).to eq(33)
      expect(e.fbtrace_id).to eq("Abc123")
    end
  end

  describe "retries" do
    before { allow(client).to receive(:sleep) }

    it "retries a 429 and succeeds once Meta stops throttling" do
      stub_request(:get, "https://graph.facebook.com/v21.0/123")
        .to_return({ status: 429, body: "{}" }, { status: 200, body: { id: "123" }.to_json })

      expect(client.get("/123")).to eq({ "id" => "123" })
    end

    it "retries Meta's own throttling codes (4/17/32/613) arriving as a bare HTTP 400" do
      stub_request(:get, "https://graph.facebook.com/v21.0/123")
        .to_return({ status: 400, body: { error: { message: "reduce the amount of data", code: 4 } }.to_json },
                   { status: 200, body: { id: "123" }.to_json })

      expect(client.get("/123")).to eq({ "id" => "123" })
    end

    it "honors a Retry-After header on a 429" do
      stub_request(:get, "https://graph.facebook.com/v21.0/123")
        .to_return({ status: 429, body: "{}", headers: { "Retry-After" => "2" } },
                   { status: 200, body: { id: "123" }.to_json })

      expect(client).to receive(:sleep).with(2.0)
      client.get("/123")
    end

    it "retries 5xx and exhausts after DEFAULT_MAX_ATTEMPTS, re-raising the last error" do
      stub = stub_request(:get, "https://graph.facebook.com/v21.0/123")
             .to_return(status: 500, body: "{}")

      expect { client.get("/123") }.to raise_error(Portage::Ucp::Instagram::ApiError)
      expect(stub).to have_been_requested.times(4)
    end

    it "does not retry a plain 400 business rejection" do
      stub = stub_request(:get, "https://graph.facebook.com/v21.0/123")
             .to_return(status: 400, body: { error: { message: "bad request", code: 100 } }.to_json)

      expect { client.get("/123") }.to raise_error(Portage::Ucp::Instagram::ApiError)
      expect(stub).to have_been_requested.times(1)
    end

    it "never retries a code-190 expired token, raising TokenExpiredError instead of ApiError" do
      stub = stub_request(:get, "https://graph.facebook.com/v21.0/123")
             .to_return(status: 400, body: { error: { message: "Error validating access token",
                                                      code: 190 } }.to_json)

      expect { client.get("/123") }
        .to raise_error(Portage::Ucp::Instagram::TokenExpiredError, /re-mint a token/)
      expect(stub).to have_been_requested.times(1)
    end
  end
end
