require "spec_helper"

RSpec.describe Portage::Ucp::Client::Session do
  let(:transport) { instance_double(Portage::Ucp::Client::Transports::Loopback) }
  let(:session) { described_class.new(transport: transport) }

  describe "read-only actions" do
    it "passes arguments straight through with no idempotency_key" do
      expect(transport).to receive(:call_tool).with(name: "search_catalog", arguments: { query: "brew", limit: 20 })

      session.search_catalog(query: "brew")
    end

    it "get_order takes no idempotency_key either" do
      expect(transport).to receive(:call_tool).with(name: "get_order", arguments: { order_id: "o1" })

      session.get_order(order_id: "o1")
    end
  end

  describe "mutating actions" do
    it "generates an idempotency_key when the caller doesn't supply one" do
      expect(transport).to receive(:call_tool) do |name:, arguments:|
        expect(name).to eq("create_cart")
        expect(arguments[:idempotency_key]).to be_a(String)
        expect(arguments[:idempotency_key]).not_to be_empty
      end

      session.create_cart(line_items: [])
    end

    it "keeps the caller's idempotency_key when one is supplied" do
      expect(transport).to receive(:call_tool).with(name: "cancel_cart", arguments: { cart_id: "c1",
                                                                                      idempotency_key: "mine" })

      session.cancel_cart(cart_id: "c1", idempotency_key: "mine")
    end

    it "generates independent keys across separate calls" do
      keys = []
      allow(transport).to receive(:call_tool) { |arguments:, **| keys << arguments[:idempotency_key] }

      session.create_cart(line_items: [])
      session.create_cart(line_items: [])

      expect(keys.uniq.size).to eq(2)
    end
  end

  describe "#complete_checkout" do
    it "validates the payment_token client-side before it goes on the wire" do
      expect(transport).not_to receive(:call_tool)

      expect { session.complete_checkout(checkout_id: "chk_1", payment_token: "4111111111111111") }
        .to raise_error(Portage::Ucp::RawPanRejectedError)
    end

    it "forwards a legitimate opaque token" do
      expect(transport).to receive(:call_tool).with(
        name: "complete_checkout",
        arguments: { checkout_id: "chk_1", payment_token: "tok_opaque", idempotency_key: "k1" }
      )

      session.complete_checkout(checkout_id: "chk_1", payment_token: "tok_opaque", idempotency_key: "k1")
    end
  end

  describe "#advertises?" do
    it "returns nil when capabilities weren't known upfront" do
      expect(session.advertises?("dev.ucp.shopping.checkout")).to be_nil
    end

    it "checks membership when capabilities were provided" do
      scoped = described_class.new(transport: transport, capabilities: ["dev.ucp.shopping.catalog"])

      expect(scoped.advertises?("dev.ucp.shopping.catalog")).to be true
      expect(scoped.advertises?("dev.ucp.shopping.checkout")).to be false
    end
  end
end
