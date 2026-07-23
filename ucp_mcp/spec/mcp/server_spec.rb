require "spec_helper"
require "support/fake_adapter"
require "stringio"

RSpec.describe UcpMcp::Mcp::Server do
  let(:adapter) { UcpMcp::Support::FakeAdapter.new }
  let(:server) { described_class.build(adapter: adapter) }

  before do
    adapter.seed_product(
      UcpMcp::Product.new(id: "prod_1", title: "Espresso Capsules", description: "Coffee capsules",
                          price: UcpMcp::Money.new(amount_minor: 1999, currency: "USD"),
                          available: true, variants: [], url: "https://example.com/prod_1")
    )
  end

  it "lists a tool for every advertised capability action" do
    response = server.handle({ jsonrpc: "2.0", id: 1, method: "tools/list" })

    tool_names = response[:result][:tools].map { |t| t[:name] }
    expect(tool_names).to include("search_catalog", "get_product", "get_cart")
  end

  it "round-trips a tools/call through the Dispatcher to the Adapter" do
    response = server.handle({
                               jsonrpc: "2.0", id: 2, method: "tools/call",
                               params: { name: "get_product", arguments: { product_id: "prod_1" } }
                             })

    result = response[:result]
    expect(result[:isError]).to be_falsey
    expect(result[:structuredContent].id).to eq("prod_1")
    expect(result[:content].first[:text]).to include("prod_1")
  end

  it "negotiates the MCP 2025-11-25 initialize handshake" do
    response = server.handle({
                               jsonrpc: "2.0", id: 4, method: "initialize",
                               params: { protocolVersion: "2025-11-25", capabilities: {},
                                         clientInfo: { name: "test-client", version: "1.0" } }
                             })

    result = response[:result]
    expect(result[:protocolVersion]).to eq("2025-11-25")
    expect(result[:capabilities]).to have_key(:tools)
    expect(result[:serverInfo][:name]).to eq("ucp_mcp")
  end

  it "returns an MCP error for an unknown tool" do
    response = server.handle({
                               jsonrpc: "2.0", id: 3, method: "tools/call",
                               params: { name: "not_a_tool", arguments: {} }
                             })

    expect(response[:error]).not_to be_nil
  end

  it "rejects a mutating call by default (§9 — no anonymous mutation)" do
    response = server.handle({
                               jsonrpc: "2.0", id: 5, method: "tools/call",
                               params: { name: "add_line_item",
                                         arguments: { cart_id: "cart_1", product_id: "prod_1",
                                                      quantity: 1, idempotency_key: "k1" } }
                             })

    expect(response[:result][:isError]).to be true
  end

  it "leaves read-only catalog calls open even with no authenticator configured" do
    response = server.handle({
                               jsonrpc: "2.0", id: 6, method: "tools/call",
                               params: { name: "get_product", arguments: { product_id: "prod_1" } }
                             })

    expect(response[:result][:isError]).to be_falsey
  end

  it "allows a mutating call once a configured authenticator approves it" do
    authenticator = Class.new(UcpMcp::Authenticator) { def call(_ctx) = :authorized }.new
    authed_server = described_class.build(adapter: adapter, authenticator: authenticator)

    response = authed_server.handle({
                                      jsonrpc: "2.0", id: 7, method: "tools/call",
                                      params: { name: "add_line_item",
                                                arguments: { cart_id: "cart_1", product_id: "prod_1",
                                                             quantity: 1, idempotency_key: "k2" } }
                                    })

    expect(response[:result][:isError]).to be_falsey
  end

  it "logs a redacted tool_called event through the configured logger (§12)" do
    io = StringIO.new
    logger = Logger.new(io)
    logger.formatter = proc { |_severity, _time, _progname, msg| "#{msg}\n" }
    logged_server = described_class.build(adapter: adapter, logger: logger)

    logged_server.handle({
                           jsonrpc: "2.0", id: 8, method: "tools/call",
                           params: { name: "get_product", arguments: { product_id: "prod_1" } }
                         })

    logged = JSON.parse(io.string.lines.last)
    expect(logged["event"]).to eq("tool_called")
    expect(logged["action"]).to eq("get_product")
  end
end
