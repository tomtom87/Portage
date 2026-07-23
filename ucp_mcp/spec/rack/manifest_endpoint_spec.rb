require "spec_helper"
require "rack/test"
require "support/fake_adapter"

RSpec.describe UcpMcp::Rack::ManifestEndpoint do
  include Rack::Test::Methods

  let(:adapter) { UcpMcp::Support::FakeAdapter.new }
  let(:manifest) { UcpMcp::Manifest.new(adapter: adapter, business: { name: "Test Roastery" }) }

  def app
    described_class.new(manifest: manifest)
  end

  it "serves the manifest as JSON on GET" do
    get "/.well-known/ucp"

    expect(last_response.status).to eq(200)
    expect(last_response.headers["content-type"]).to eq("application/json")

    body = JSON.parse(last_response.body)
    expect(body["ucp_version"]).to eq("2026-04-08")
    expect(body["business"]).to eq("name" => "Test Roastery")
  end

  it "rejects non-GET requests" do
    post "/.well-known/ucp"

    expect(last_response.status).to eq(404)
  end

  context "with payment handlers configured" do
    let(:manifest) do
      UcpMcp::Manifest.new(adapter: adapter, business: { name: "Test Roastery" },
                           payment_handlers: [{ type: "card_token" }])
    end

    it "refuses to serve over plaintext HTTP (§9)" do
      get "/.well-known/ucp"

      expect(last_response.status).to eq(496)
    end

    it "serves normally over TLS" do
      get "/.well-known/ucp", {}, { "HTTPS" => "on" }

      expect(last_response.status).to eq(200)
    end

    it "serves over plaintext when explicitly allowed for local development" do
      def app
        described_class.new(manifest: manifest, allow_insecure: true)
      end

      get "/.well-known/ucp"

      expect(last_response.status).to eq(200)
    end
  end
end
