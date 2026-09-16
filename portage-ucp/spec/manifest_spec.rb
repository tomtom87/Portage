require "spec_helper"
require "support/fake_adapter"

RSpec.describe Portage::Ucp::Manifest do
  let(:adapter) { Portage::Ucp::Support::FakeAdapter.new }
  let(:business) { { name: "Test Roastery", url: "https://example.com" } }
  let(:manifest) { described_class.new(adapter: adapter, business: business) }

  it "nests everything under a ucp envelope" do
    expect(manifest.to_h.keys).to eq([:ucp])
  end

  it "reports the UCP spec version" do
    expect(manifest.to_h[:ucp][:version]).to eq("2026-04-08")
  end

  it "keys capabilities by name, matching what live UCP stores actually serve" do
    capabilities = manifest.to_h[:ucp][:capabilities]

    expect(capabilities.keys).to include("dev.ucp.shopping.catalog", "dev.ucp.shopping.cart",
                                         "dev.ucp.shopping.checkout", "dev.ucp.shopping.order")
    expect(capabilities.keys).not_to include("dev.ucp.shopping.identity")
    expect(capabilities["dev.ucp.shopping.checkout"]).to eq([{ version: "1" }])
  end

  it "passes through business info, payment handlers, and signing keys verbatim" do
    manifest = described_class.new(
      adapter: adapter, business: business,
      payment_handlers: [{ type: "card_token" }], signing_keys: [{ kid: "k1", public_key: "..." }]
    )

    result = manifest.to_h[:ucp]
    expect(result[:business]).to eq(business)
    expect(result[:payment_handlers]).to eq([{ type: "card_token" }])
    expect(result[:signing_keys]).to eq([{ kid: "k1", public_key: "..." }])
  end

  it "includes the services array a client needs to find where to connect" do
    manifest = described_class.new(
      adapter: adapter, business: business,
      services: [{ transport: "mcp", endpoint: "https://example.com/mcp" }]
    )

    expect(manifest.to_h[:ucp][:services]).to eq([{ transport: "mcp", endpoint: "https://example.com/mcp" }])
  end

  it "defaults services to an empty array when none are configured" do
    expect(manifest.to_h[:ucp][:services]).to eq([])
  end

  it "has no signature block when no signer is configured" do
    expect(manifest.to_h[:ucp]).not_to have_key(:signature)
  end

  it "signs the manifest with a consumer-provided signer, without generating keys itself" do
    signer = Class.new do
      def kid = "k1"
      def sign(canonical_json) = "sig(#{canonical_json.bytesize})"
    end.new

    signed = described_class.new(adapter: adapter, business: business, signer: signer).to_h[:ucp]

    expect(signed[:signature][:kid]).to eq("k1")
    expected_bytesize = JSON.generate(signed.except(:signature)).bytesize
    expect(Base64.strict_decode64(signed[:signature][:value])).to eq("sig(#{expected_bytesize})")
  end

  it "falls back to Portage::Ucp.configuration for collaborators not passed explicitly" do
    Portage::Ucp.configure do |c|
      c.payment_handlers = [{ type: "configured_handler" }]
      c.services = [{ transport: "mcp", endpoint: "https://configured.example.com/mcp" }]
    end

    result = described_class.new(adapter: adapter, business: business).to_h[:ucp]

    expect(result[:payment_handlers]).to eq([{ type: "configured_handler" }])
    expect(result[:services]).to eq([{ transport: "mcp", endpoint: "https://configured.example.com/mcp" }])
  ensure
    Portage::Ucp.instance_variable_set(:@configuration, nil)
  end
end
