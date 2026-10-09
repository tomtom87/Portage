require "spec_helper"
require "support/fake_adapter"

RSpec.describe Portage::Ucp::Manifest do
  let(:adapter) { Portage::Ucp::Support::FakeAdapter.new }
  let(:business) { { name: "Test Roastery", url: "https://example.com" } }
  let(:manifest) { described_class.new(adapter: adapter, business: business) }

  it "nests everything under a ucp envelope, with the JWK Set as a root sibling" do
    expect(manifest.to_h.keys).to eq(%i[ucp keys])
  end

  it "validates against the 2026-08-25 business profile schema (keys at the root, ucp.signing_keys gone)" do
    validator = Portage::Ucp::SchemaValidator.new(version: "2026-08-25")
    jwk = { kid: "k1", kty: "OKP", crv: "Ed25519", x: "11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo" }
    document = described_class.new(
      adapter: adapter, business: business, signing_keys: [jwk],
      services: [{ transport: "mcp", endpoint: "https://example.com/mcp" }],
      payment_handlers: { "com.example.pay" => [{ id: "pay_1" }] }
    ).to_h

    errors = validator.errors_for("schemas/profile.json#/$defs/business_schema", JSON.parse(JSON.generate(document)))

    expect(errors).to eq([])
  end

  it "reports the UCP spec version" do
    expect(manifest.to_h[:ucp][:version]).to eq("2026-08-25")
  end

  it "keys capabilities by name, matching what live UCP stores actually serve" do
    capabilities = manifest.to_h[:ucp][:capabilities]

    expect(capabilities.keys).to include("dev.ucp.shopping.catalog", "dev.ucp.shopping.cart",
                                         "dev.ucp.shopping.checkout", "dev.ucp.shopping.order")
    expect(capabilities.keys).not_to include("dev.ucp.shopping.identity")
    expect(capabilities["dev.ucp.shopping.checkout"])
      .to eq([{ version: "2026-08-25", schema: "https://ucp.dev/2026-08-25/schemas/shopping/checkout.json" }])
  end

  it "passes through business info, payment handlers (adding a default version), and signing keys verbatim" do
    manifest = described_class.new(
      adapter: adapter, business: business,
      payment_handlers: { "com.example.pay" => [{ id: "pay_1" }] }, signing_keys: [{ kid: "k1", public_key: "..." }]
    )

    document = manifest.to_h
    expect(document[:ucp][:business]).to eq(business)
    expect(document[:ucp][:payment_handlers])
      .to eq({ "com.example.pay" => [{ version: "2026-08-25", id: "pay_1" }] })
    expect(document[:keys]).to eq([{ kid: "k1", public_key: "..." }])
    expect(document[:ucp]).not_to have_key(:signing_keys)
  end

  it "files a bare services array under dev.ucp.shopping, keyed as 2026-08-25 requires" do
    manifest = described_class.new(
      adapter: adapter, business: business,
      services: [{ transport: "mcp", endpoint: "https://example.com/mcp" }]
    )

    expect(manifest.to_h[:ucp][:services]).to eq(
      "dev.ucp.shopping" => [{ version: "2026-08-25", transport: "mcp", endpoint: "https://example.com/mcp" }]
    )
  end

  it "passes an already-keyed services object through, keeping an entry's own version" do
    services = { "dev.ucp.shopping" => [{ version: "2026-04-08", transport: "rest", endpoint: "https://example.com/r" }] }

    expect(described_class.new(adapter: adapter, business: business, services: services).to_h[:ucp][:services])
      .to eq(services)
  end

  it "defaults services and payment_handlers to empty objects when none are configured" do
    expect(manifest.to_h[:ucp].values_at(:services, :payment_handlers)).to eq([{}, {}])
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
      c.payment_handlers = { "com.example.pay" => [{ id: "configured" }] }
      c.services = [{ transport: "mcp", endpoint: "https://configured.example.com/mcp" }]
    end

    result = described_class.new(adapter: adapter, business: business).to_h[:ucp]

    expect(result[:payment_handlers]).to eq({ "com.example.pay" => [{ version: "2026-08-25", id: "configured" }] })
    expect(result[:services]).to eq(
      "dev.ucp.shopping" => [
        { version: "2026-08-25", transport: "mcp", endpoint: "https://configured.example.com/mcp" }
      ]
    )
  ensure
    Portage::Ucp.instance_variable_set(:@configuration, nil)
  end
end
