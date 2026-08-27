require "spec_helper"
require "support/fake_adapter"
require "support/product_factory"

RSpec.describe Portage::Ucp::Dispatcher do
  let(:adapter) { Portage::Ucp::Support::FakeAdapter.new }
  let(:dispatcher) { described_class.new(adapter: adapter) }
  let(:product) { ProductFactory.build(id: "prod_1", title: "Cold Brew", price_minor: 500) }

  before { adapter.seed_product(product) }

  it "accepts a UCP-shaped request and routes it to the matching adapter method, wrapped in the ucp envelope" do
    response = dispatcher.call(capability: "dev.ucp.shopping.catalog", action: "search_catalog",
                               arguments: { query: "brew", limit: 10 })

    expect(response[:structuredContent]["products"]).to eq([product.to_wire_h])
    expect(response[:structuredContent]["ucp"]).to eq({ "version" => "2026-04-08" })
  end

  it "wraps the adapter's return value as both structuredContent and a text content block" do
    response = dispatcher.call(capability: "dev.ucp.shopping.catalog", action: "get_product",
                               arguments: { product_id: "prod_1" })

    expect(response[:structuredContent]["product"]).to eq(product.to_wire_h)
  end

  it "routes a cart mutation through, idempotency_key included, wrapped in the ucp envelope" do
    response = dispatcher.call(capability: "dev.ucp.shopping.cart", action: "create_cart",
                               arguments: { line_items: [{ product_id: "prod_1", quantity: 1 }],
                                            idempotency_key: "k1" })

    expect(response[:structuredContent]["line_items"].size).to eq(1)
    expect(response[:structuredContent]["ucp"]).to eq({ "version" => "2026-04-08" })
  end

  it "rejects a complete_checkout call whose payment_token looks like a raw PAN (§9)" do
    checkout = dispatcher.call(capability: "dev.ucp.shopping.checkout", action: "create_checkout",
                               arguments: { line_items: [], idempotency_key: "chk1" })[:structuredContent]

    expect do
      dispatcher.call(capability: "dev.ucp.shopping.checkout", action: "complete_checkout",
                      arguments: { checkout_id: checkout["id"], payment_token: "4111111111111111",
                                   idempotency_key: "chk1-complete" })
    end.to raise_error(Portage::Ucp::RawPanRejectedError)
  end

  it "routes cancel_order/request_return/refund_order through as dev.ucp.shopping.order actions (§16)" do
    checkout = dispatcher.call(capability: "dev.ucp.shopping.checkout", action: "create_checkout",
                               arguments: { line_items: [{ product_id: "prod_1", quantity: 2 }],
                                            idempotency_key: "chk-oc" })[:structuredContent]
    confirmation = dispatcher.call(capability: "dev.ucp.shopping.checkout", action: "complete_checkout",
                                   arguments: { checkout_id: checkout["id"], payment_token: "tok_visa",
                                                idempotency_key: "chk-oc-complete" })[:structuredContent]["order"]
    order_id = confirmation["id"]
    line_item_id = dispatcher.call(capability: "dev.ucp.shopping.order", action: "get_order",
                                   arguments: { order_id: order_id })[:structuredContent]["line_items"][0]["id"]

    refunded = dispatcher.call(capability: "dev.ucp.shopping.order", action: "refund_order",
                               arguments: { order_id: order_id,
                                            line_items: [{ id: line_item_id, quantity: 1 }],
                                            idempotency_key: "ref1" })[:structuredContent]
    expect(refunded["adjustments"].size).to eq(1)
    expect(refunded["adjustments"][0]["type"]).to eq("refund")

    returned = dispatcher.call(capability: "dev.ucp.shopping.order", action: "request_return",
                               arguments: { order_id: order_id,
                                            line_items: [{ id: line_item_id, quantity: 1 }],
                                            idempotency_key: "ret1", reason: "wrong size" })[:structuredContent]
    expect(returned["adjustments"].map { |a| a["type"] }).to eq(%w[refund return])
    expect(returned["adjustments"][1]["status"]).to eq("pending")

    canceled = dispatcher.call(capability: "dev.ucp.shopping.order", action: "cancel_order",
                               arguments: { order_id: order_id, idempotency_key: "can1" })[:structuredContent]
    expect(canceled["adjustments"].last["type"]).to eq("cancellation")
  end

  it "raises UnknownCapabilityError for a capability name that isn't registered" do
    expect { dispatcher.call(capability: "dev.ucp.shopping.nonexistent", action: "whatever", arguments: {}) }
      .to raise_error(Portage::Ucp::UnknownCapabilityError, /dev\.ucp\.shopping\.nonexistent/)
  end

  it "raises UnknownActionError for an action not defined on the capability" do
    expect { dispatcher.call(capability: "dev.ucp.shopping.catalog", action: "not_a_real_action", arguments: {}) }
      .to raise_error(Portage::Ucp::UnknownActionError, /not_a_real_action/)
  end

  it "raises CapabilityNotAdvertisedError when the adapter hasn't overridden any backing method" do
    bare_adapter = Portage::Ucp::Adapter.new
    dispatcher = described_class.new(adapter: bare_adapter)

    expect do
      dispatcher.call(capability: "dev.ucp.shopping.identity", action: "link_identity", arguments: { oauth_token: "t" })
    end
      .to raise_error(Portage::Ucp::CapabilityNotAdvertisedError, /dev\.ucp\.shopping\.identity/)
  end
end
