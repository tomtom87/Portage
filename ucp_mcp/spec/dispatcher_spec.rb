require "spec_helper"
require "support/fake_adapter"

RSpec.describe UcpMcp::Dispatcher do
  let(:adapter) { UcpMcp::Support::FakeAdapter.new }
  let(:dispatcher) { described_class.new(adapter: adapter) }
  let(:product) do
    UcpMcp::Product.new(id: "prod_1", title: "Cold Brew", description: "desc",
                        price: UcpMcp::Money.new(amount_minor: 500, currency: "USD"),
                        available: true, variants: [], url: "https://example.com/prod_1")
  end

  before { adapter.seed_product(product) }

  it "accepts a UCP-shaped request and routes it to the matching adapter method" do
    response = dispatcher.call(capability: "dev.ucp.shopping.catalog", action: "search_catalog",
                               arguments: { query: "brew", limit: 10 })

    expect(response[:structuredContent]).to eq([product])
  end

  it "wraps the adapter's return value as both structuredContent and a text content block" do
    response = dispatcher.call(capability: "dev.ucp.shopping.catalog", action: "get_product",
                               arguments: { product_id: "prod_1" })

    expect(response[:structuredContent]).to eq(product)
    expect(response[:content]).to eq([{ type: "text", text: product.inspect }])
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
    end.to raise_error(UcpMcp::RawPanRejectedError)
  end

  it "raises UnknownCapabilityError for a capability name that isn't registered" do
    expect { dispatcher.call(capability: "dev.ucp.shopping.nonexistent", action: "whatever", arguments: {}) }
      .to raise_error(UcpMcp::UnknownCapabilityError, /dev\.ucp\.shopping\.nonexistent/)
  end

  it "raises UnknownActionError for an action not defined on the capability" do
    expect { dispatcher.call(capability: "dev.ucp.shopping.catalog", action: "not_a_real_action", arguments: {}) }
      .to raise_error(UcpMcp::UnknownActionError, /not_a_real_action/)
  end

  it "raises CapabilityNotAdvertisedError when the adapter hasn't overridden any backing method" do
    bare_adapter = UcpMcp::Adapter.new
    dispatcher = described_class.new(adapter: bare_adapter)

    expect do
      dispatcher.call(capability: "dev.ucp.shopping.identity", action: "link_identity", arguments: { oauth_token: "t" })
    end
      .to raise_error(UcpMcp::CapabilityNotAdvertisedError, /dev\.ucp\.shopping\.identity/)
  end
end
