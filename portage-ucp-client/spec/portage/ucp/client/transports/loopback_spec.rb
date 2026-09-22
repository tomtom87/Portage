require "spec_helper"
require "stringio"
require "support/fake_adapter"

RSpec.describe Portage::Ucp::Client::Transports::Loopback do
  let(:adapter) { Portage::Ucp::Client::Support::FakeAdapter.new }
  let(:transport) { described_class.new(adapter: adapter) }

  before do
    price = Portage::Ucp::Price.new(amount: 500, currency: "USD")
    variant = Portage::Ucp::Variant.new(id: "p1_default", title: "Cold Brew",
                                        description: Portage::Ucp::Description.new(plain: "d"), price: price,
                                        availability: { "available" => true })
    adapter.seed_product(
      Portage::Ucp::Product.new(id: "p1", title: "Cold Brew", description: Portage::Ucp::Description.new(plain: "d"),
                                price_range: Portage::Ucp::PriceRange.new(min: price, max: price),
                                variants: [variant], url: "u")
    )
  end

  it "runs a tool call in-process and returns the structuredContent" do
    result = transport.call_tool(name: "search_catalog", arguments: { query: "cold", limit: 5 })

    expect(result["products"].first["id"]).to eq("p1")
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

  it "threads Session's meta: through to the Dispatcher as agent_profile (round trip, §23-style)" do
    io = StringIO.new
    logger = Logger.new(io)
    logger.formatter = proc { |_severity, _time, _progname, msg| "#{msg}\n" }
    logged_transport = described_class.new(adapter: adapter, logger: logger)
    session = Portage::Ucp::Client::Session.new(transport: logged_transport)

    session.search_catalog(query: "cold", meta: { "ucp-agent.profile" => "agent-123" })

    logged = JSON.parse(io.string.lines.first)
    expect(logged["agent_profile"]).to eq("agent-123")
  end

  it "also threads the `agent_profile:` key Buy#agent_meta actually sends, not just the server's own key" do
    io = StringIO.new
    logger = Logger.new(io)
    logger.formatter = proc { |_severity, _time, _progname, msg| "#{msg}\n" }
    logged_transport = described_class.new(adapter: adapter, logger: logger)
    session = Portage::Ucp::Client::Session.new(transport: logged_transport)

    session.search_catalog(query: "cold", meta: { agent_profile: "agent-456" })

    logged = JSON.parse(io.string.lines.first)
    expect(logged["agent_profile"]).to eq("agent-456")
  end

  # `context`/`cart_id` are Transports::Http wire concerns. This transport
  # hands arguments to the Dispatcher, which splats them into an Adapter
  # method signature that has no such keywords — so they get dropped rather
  # than raising ArgumentError deep in an adapter.
  it "drops real-UCP-only arguments before they reach the Dispatcher" do
    arguments = { query: "brew", limit: 5, context: { currency: "USD" } }

    expect { transport.call_tool(name: "search_catalog", arguments: arguments) }.not_to raise_error
  end

  it "assigns a fresh JSON-RPC id per call" do
    transport.call_tool(name: "search_catalog", arguments: { query: "cold", limit: 5 })
    transport.call_tool(name: "search_catalog", arguments: { query: "cold", limit: 5 })

    expect(transport.instance_variable_get(:@next_id)).to eq(2)
  end
end
