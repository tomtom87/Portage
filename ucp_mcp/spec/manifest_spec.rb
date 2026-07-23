require "spec_helper"
require "support/fake_adapter"

RSpec.describe UcpMcp::Manifest do
  let(:adapter) { UcpMcp::Support::FakeAdapter.new }
  let(:business) { { name: "Test Roastery", url: "https://example.com" } }
  let(:manifest) { described_class.new(adapter: adapter, business: business) }

  it "reports the UCP spec version" do
    expect(manifest.to_h[:ucp_version]).to eq("2026-04-08")
  end

  it "includes only capabilities the adapter overrides" do
    names = manifest.to_h[:capabilities].map { |c| c[:name] }

    expect(names).to include("dev.ucp.shopping.catalog", "dev.ucp.shopping.cart", "dev.ucp.shopping.checkout")
    expect(names).not_to include("dev.ucp.shopping.order", "dev.ucp.shopping.identity")
  end

  it "passes through business info, payment handlers, and signing keys verbatim" do
    manifest = described_class.new(
      adapter: adapter, business: business,
      payment_handlers: [{ type: "card_token" }], signing_keys: [{ kid: "k1", public_key: "..." }]
    )

    result = manifest.to_h
    expect(result[:business]).to eq(business)
    expect(result[:payment_handlers]).to eq([{ type: "card_token" }])
    expect(result[:signing_keys]).to eq([{ kid: "k1", public_key: "..." }])
  end

  it "has no signature block when no signer is configured" do
    expect(manifest.to_h).not_to have_key(:signature)
  end

  it "signs the manifest with a consumer-provided signer, without generating keys itself" do
    signer = Class.new do
      def kid = "k1"
      def sign(canonical_json) = "sig(#{canonical_json.bytesize})"
    end.new

    signed = described_class.new(adapter: adapter, business: business, signer: signer).to_h

    expect(signed[:signature][:kid]).to eq("k1")
    expected_bytesize = JSON.generate(signed.except(:signature)).bytesize
    expect(Base64.strict_decode64(signed[:signature][:value])).to eq("sig(#{expected_bytesize})")
  end
end
