require "spec_helper"
require "stringio"

RSpec.describe UcpMcp::Observability do
  let(:io) { StringIO.new }
  let(:logger) { Logger.new(io).tap { |l| l.formatter = proc { |_severity, _time, _progname, msg| "#{msg}\n" } } }

  it "logs the event name alongside the given fields" do
    described_class.log(logger, "tool_called", capability: "dev.ucp.shopping.cart", action: "get_cart")

    logged = JSON.parse(io.string.lines.last)
    expect(logged["event"]).to eq("tool_called")
    expect(logged["capability"]).to eq("dev.ucp.shopping.cart")
    expect(logged["action"]).to eq("get_cart")
  end

  it "redacts payment_token, oauth_token, and authorization at any nesting depth" do
    described_class.log(logger, "checkout_completed",
                        arguments: { payment_token: "tok_live_secret", nested: { oauth_token: "oauth_secret" } },
                        authorization: "Bearer secret")

    logged = JSON.parse(io.string.lines.last)
    expect(logged["arguments"]["payment_token"]).to eq("[REDACTED]")
    expect(logged["arguments"]["nested"]["oauth_token"]).to eq("[REDACTED]")
    expect(logged["authorization"]).to eq("[REDACTED]")
  end

  it "redacts within arrays too" do
    described_class.log(logger, "batch", items: [{ oauth_token: "a" }, { safe: "b" }])

    logged = JSON.parse(io.string.lines.last)
    expect(logged["items"]).to eq([{ "oauth_token" => "[REDACTED]" }, { "safe" => "b" }])
  end

  it "leaves non-sensitive fields untouched" do
    described_class.log(logger, "tool_called", capability: "dev.ucp.shopping.cart", quantity: 2)

    logged = JSON.parse(io.string.lines.last)
    expect(logged["quantity"]).to eq(2)
  end
end
