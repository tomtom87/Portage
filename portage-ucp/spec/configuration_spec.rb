require "spec_helper"
require "support/fake_adapter"
require "support/product_factory"

RSpec.describe Portage::Ucp do
  after do
    described_class.instance_variable_set(:@configuration, nil)
  end

  it "has permissive-but-safe defaults matching the gem's own no-anonymous-mutation stance" do
    config = described_class.configuration

    expect(config.registry).to be_a(Portage::Ucp::CapabilityRegistry)
    expect(config.authenticator).to be_a(Portage::Ucp::UnconfiguredAuthenticator)
    expect(config.rate_limiter).to be_a(Portage::Ucp::NullRateLimiter)
    expect(config.payment_handlers).to eq([])
    expect(config.signing_keys).to eq([])
    expect(config.services).to eq([])
  end

  it "yields the same configuration instance every call, letting a consumer set it once" do
    authenticator = Class.new(Portage::Ucp::Authenticator) { def call(_ctx) = :ok }.new

    described_class.configure { |c| c.authenticator = authenticator }

    expect(described_class.configuration.authenticator).to equal(authenticator)
  end

  it "flows into Mcp::Server.build as the default authenticator" do
    authenticator = Class.new(Portage::Ucp::Authenticator) { def call(_ctx) = :ok }.new
    described_class.configure { |c| c.authenticator = authenticator }

    adapter = Portage::Ucp::Support::FakeAdapter.new
    adapter.seed_product(ProductFactory.build(id: "p1", title: "x", price_minor: 100))
    server = Portage::Ucp::Mcp::Server.build(adapter: adapter)

    response = server.handle({
                               jsonrpc: "2.0", id: 1, method: "tools/call",
                               params: { name: "create_cart",
                                         arguments: { line_items: [{ product_id: "p1", quantity: 1 }],
                                                      idempotency_key: "k1" } }
                             })

    expect(response[:result][:isError]).to be_falsey
  end
end
