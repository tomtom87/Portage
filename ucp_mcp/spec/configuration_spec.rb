require "spec_helper"
require "support/fake_adapter"

RSpec.describe UcpMcp do
  after do
    described_class.instance_variable_set(:@configuration, nil)
  end

  it "has permissive-but-safe defaults matching the gem's own no-anonymous-mutation stance" do
    config = described_class.configuration

    expect(config.registry).to be_a(UcpMcp::CapabilityRegistry)
    expect(config.authenticator).to be_a(UcpMcp::UnconfiguredAuthenticator)
    expect(config.rate_limiter).to be_a(UcpMcp::NullRateLimiter)
    expect(config.payment_handlers).to eq([])
    expect(config.signing_keys).to eq([])
  end

  it "yields the same configuration instance every call, letting a consumer set it once" do
    authenticator = Class.new(UcpMcp::Authenticator) { def call(_ctx) = :ok }.new

    described_class.configure { |c| c.authenticator = authenticator }

    expect(described_class.configuration.authenticator).to equal(authenticator)
  end

  it "flows into Mcp::Server.build as the default authenticator" do
    authenticator = Class.new(UcpMcp::Authenticator) { def call(_ctx) = :ok }.new
    described_class.configure { |c| c.authenticator = authenticator }

    adapter = UcpMcp::Support::FakeAdapter.new
    adapter.seed_product(
      UcpMcp::Product.new(id: "p1", title: "x", description: "d",
                          price: UcpMcp::Money.new(amount_minor: 100, currency: "USD"),
                          available: true, variants: [], url: "u")
    )
    server = UcpMcp::Mcp::Server.build(adapter: adapter)

    response = server.handle({
                               jsonrpc: "2.0", id: 1, method: "tools/call",
                               params: { name: "add_line_item",
                                         arguments: { cart_id: "c1", product_id: "p1",
                                                      quantity: 1, idempotency_key: "k1" } }
                             })

    expect(response[:result][:isError]).to be_falsey
  end
end
