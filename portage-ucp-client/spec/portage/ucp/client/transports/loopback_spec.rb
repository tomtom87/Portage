require "spec_helper"
require "support/fake_adapter"

RSpec.describe Portage::Ucp::Client::Transports::Loopback do
  let(:adapter) { Portage::Ucp::Client::Support::FakeAdapter.new }
  let(:transport) { described_class.new(adapter: adapter) }

  before do
    adapter.seed_product(
      Portage::Ucp::Product.new(id: "p1", title: "Cold Brew", description: "d",
                                price: Portage::Ucp::Money.new(amount_minor: 500, currency: "USD"),
                                available: true, variants: [], url: "u")
    )
  end

  it "runs a tool call in-process and returns the structuredContent" do
    result = transport.call_tool(name: "search_catalog", arguments: { query: "cold", limit: 5 })

    expect(result.first.id).to eq("p1")
  end

  it "runs the real authenticator/rate-limiter/Dispatcher stack, not a bypass" do
    permissive = Class.new(Portage::Ucp::Authenticator) { def call(_ctx) = :ok }.new
    authed_transport = described_class.new(adapter: adapter, authenticator: permissive)

    checkout = authed_transport.call_tool(
      name: "create_checkout",
      arguments: { line_items: [{ product_id: "p1", quantity: 1 }], idempotency_key: "k1" }
    )

    expect(checkout["status"]).to eq("ready_for_complete")
    expect(checkout["ucp"]["version"]).to eq("2026-04-08")
  end

  it "enforces the no-anonymous-mutation default when no authenticator is configured" do
    expect do
      transport.call_tool(
        name: "create_checkout",
        arguments: { line_items: [{ product_id: "p1", quantity: 1 }], idempotency_key: "k1" }
      )
    end.to raise_error(Portage::Ucp::Client::ServerError, /no authenticator configured/)
  end

  it "raises ServerError when the underlying tool call reports isError" do
    expect { transport.call_tool(name: "get_product", arguments: {}) }
      .to raise_error(Portage::Ucp::Client::ServerError, /Missing required arguments/)
  end

  it "assigns a fresh JSON-RPC id per call" do
    transport.call_tool(name: "search_catalog", arguments: { query: "cold", limit: 5 })
    transport.call_tool(name: "search_catalog", arguments: { query: "cold", limit: 5 })

    expect(transport.instance_variable_get(:@next_id)).to eq(2)
  end
end
