require "spec_helper"
require "support/fake_adapter"
require "support/product_factory"
require "stringio"

RSpec.describe Portage::Ucp::Mcp::Server do
  let(:adapter) { Portage::Ucp::Support::FakeAdapter.new }
  let(:server) { described_class.build(adapter: adapter) }

  before do
    adapter.seed_product(ProductFactory.build(id: "prod_1", title: "Espresso Capsules", price_minor: 1999))
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
    expect(result[:structuredContent]["product"]["id"]).to eq("prod_1")
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
    expect(result[:serverInfo][:name]).to eq("portage-ucp")
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
                               params: { name: "create_cart",
                                         arguments: { line_items: [{ product_id: "prod_1", quantity: 1 }],
                                                      idempotency_key: "k1" } }
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
    authenticator = Class.new(Portage::Ucp::Authenticator) { def call(_ctx) = :authorized }.new
    authed_server = described_class.build(adapter: adapter, authenticator: authenticator)

    response = authed_server.handle({
                                      jsonrpc: "2.0", id: 7, method: "tools/call",
                                      params: { name: "create_cart",
                                                arguments: { line_items: [{ product_id: "prod_1", quantity: 1 }],
                                                             idempotency_key: "k2" } }
                                    })

    expect(response[:result][:isError]).to be_falsey
  end

  it "leaves mutating calls unlimited by default (no bundled rate limiter, §9)" do
    authenticator = Class.new(Portage::Ucp::Authenticator) { def call(_ctx) = :authorized }.new
    unlimited_server = described_class.build(adapter: adapter, authenticator: authenticator)

    response = unlimited_server.handle({
                                         jsonrpc: "2.0", id: 9, method: "tools/call",
                                         params: { name: "create_cart",
                                                   arguments: { line_items: [{ product_id: "prod_1", quantity: 1 }],
                                                                idempotency_key: "k3" } }
                                       })

    expect(response[:result][:isError]).to be_falsey
  end

  it "blocks a mutating call once a configured RateLimiter says so (§9)" do
    authenticator = Class.new(Portage::Ucp::Authenticator) { def call(_ctx) = :authorized }.new
    limiter = Class.new(Portage::Ucp::RateLimiter) do
      def check!(_key, _capability) = raise(Portage::Ucp::RateLimitExceededError, "too many requests")
    end.new
    limited_server = described_class.build(adapter: adapter, authenticator: authenticator, rate_limiter: limiter)

    response = limited_server.handle({
                                       jsonrpc: "2.0", id: 10, method: "tools/call",
                                       params: { name: "create_cart",
                                                 arguments: { line_items: [{ product_id: "prod_1", quantity: 1 }],
                                                              idempotency_key: "k4" } }
                                     })

    expect(response[:result][:isError]).to be true
  end

  it "never rate-limits read-only catalog calls" do
    limiter = Class.new(Portage::Ucp::RateLimiter) do
      def check!(_key, _capability) = raise(Portage::Ucp::RateLimitExceededError, "too many requests")
    end.new
    limited_server = described_class.build(adapter: adapter, rate_limiter: limiter)

    response = limited_server.handle({
                                       jsonrpc: "2.0", id: 11, method: "tools/call",
                                       params: { name: "get_product", arguments: { product_id: "prod_1" } }
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

  it "generates a correlation id and stamps it on both events when no traceparent is inbound (§23)" do
    io = StringIO.new
    logger = Logger.new(io)
    logger.formatter = proc { |_severity, _time, _progname, msg| "#{msg}\n" }
    logged_server = described_class.build(adapter: adapter, logger: logger)

    logged_server.handle({
                           jsonrpc: "2.0", id: 12, method: "tools/call",
                           params: { name: "get_product", arguments: { product_id: "prod_1" } }
                         })

    received, called = io.string.lines.map { |line| JSON.parse(line) }
    expect(received["correlation_id"]).not_to be_nil
    expect(called["correlation_id"]).to eq(received["correlation_id"])
  end

  it "prefers the inbound W3C traceparent from _meta over generating one (§23)" do
    io = StringIO.new
    logger = Logger.new(io)
    logger.formatter = proc { |_severity, _time, _progname, msg| "#{msg}\n" }
    logged_server = described_class.build(adapter: adapter, logger: logger)

    logged_server.handle({
                           jsonrpc: "2.0", id: 13, method: "tools/call",
                           params: { name: "get_product", arguments: { product_id: "prod_1" },
                                     _meta: { traceparent: "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01" } }
                         })

    received, called = io.string.lines.map { |line| JSON.parse(line) }
    expect(received["correlation_id"]).to eq("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01")
    expect(called["correlation_id"]).to eq(received["correlation_id"])
  end

  it "never reuses a generated correlation id across requests (no Context-memoization trap, §23)" do
    io = StringIO.new
    logger = Logger.new(io)
    logger.formatter = proc { |_severity, _time, _progname, msg| "#{msg}\n" }
    logged_server = described_class.build(adapter: adapter, logger: logger)

    logged_server.handle({
                           jsonrpc: "2.0", id: 14, method: "tools/call",
                           params: { name: "get_product", arguments: { product_id: "prod_1" } }
                         })
    logged_server.handle({
                           jsonrpc: "2.0", id: 15, method: "tools/call",
                           params: { name: "get_product", arguments: { product_id: "prod_1" } }
                         })

    first_id, = io.string.lines.first(2).map { |line| JSON.parse(line)["correlation_id"] }
    second_id, = io.string.lines.last(2).map { |line| JSON.parse(line)["correlation_id"] }
    expect(first_id).not_to eq(second_id)
  end
end
