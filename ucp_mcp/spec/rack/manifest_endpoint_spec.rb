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
end
