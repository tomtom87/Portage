require "spec_helper"
require "stringio"

RSpec.describe Portage::Ucp::Observability do
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

  it "redacts identity and address PII (§23 step 4) alongside the credential keys" do
    described_class.log(logger, "tool_called",
                        arguments: { email: "shopper@example.com", first_name: "A", last_name: "B",
                                     phone_number: "+1", street_address: "1 Main St", extended_address: "Apt 2",
                                     address_locality: "Springfield", address_region: "IL",
                                     address_country: "US", postal_code: "62704" })

    logged = JSON.parse(io.string.lines.last)
    logged["arguments"].each_value { |v| expect(v).to eq("[REDACTED]") }
  end

  it "redacts psp_reference (opaque payment method reference)" do
    described_class.log(logger, "tool_called", arguments: { psp_reference: "psp_live_secret" })

    logged = JSON.parse(io.string.lines.last)
    expect(logged["arguments"]["psp_reference"]).to eq("[REDACTED]")
  end

  it "leaves non-sensitive fields untouched" do
    described_class.log(logger, "tool_called", capability: "dev.ucp.shopping.cart", quantity: 2)

    logged = JSON.parse(io.string.lines.last)
    expect(logged["quantity"]).to eq(2)
  end

  describe "opt-in OTel span emission" do
    let(:tracer) { double("tracer") }

    around do |example|
      previous = Portage::Ucp.configuration.tracer
      example.run
      Portage::Ucp.configuration.tracer = previous
    end

    it "never calls a tracer when none is configured" do
      Portage::Ucp.configuration.tracer = nil

      expect { described_class.log(logger, "tool_called", capability: "dev.ucp.shopping.cart") }.not_to raise_error
    end

    it "emits a span with the event name and flattened, already-redacted attributes" do
      Portage::Ucp.configuration.tracer = tracer
      allow(tracer).to receive(:in_span).and_yield

      described_class.log(logger, "tool_called",
                          capability: "dev.ucp.shopping.cart",
                          arguments: { quantity: 2, payment_token: "tok_live_secret" })

      expect(tracer).to have_received(:in_span).with(
        "tool_called",
        attributes: { "capability" => "dev.ucp.shopping.cart", "arguments.quantity" => 2,
                      "arguments.payment_token" => "[REDACTED]" }
      )
    end

    it "stringifies array attributes and drops nil ones, since OTel attributes can't hold either" do
      Portage::Ucp.configuration.tracer = tracer
      allow(tracer).to receive(:in_span).and_yield

      described_class.log(logger, "batch", ids: [1, 2], skipped: nil)

      expect(tracer).to have_received(:in_span).with("batch", attributes: { "ids" => %w[1 2] })
    end
  end
end
