require "spec_helper"
require "portage/ucp/rspec"
require "support/product_factory"
require "stringio"

# Runs the conformance kit against the gem's own ReferenceAdapter — proves
# both that the shipped reference implementation actually satisfies the
# contract, and that the kit itself (portage/ucp/rspec.rb) is wired up
# correctly, before any third-party adapter gem depends on it.
RSpec.describe Portage::Ucp::ReferenceAdapter do
  let(:adapter) { described_class.new }
  let(:existing_product_id) { "prod_1" }
  let(:out_of_stock_product_id) { "oos_1" }

  before do
    adapter.seed_product(ProductFactory.build(id: "prod_1", title: "Cold Brew", price_minor: 500))
    adapter.seed_product(ProductFactory.build(id: "oos_1", title: "Sold Out Blend", price_minor: 700,
                                              available: false))
  end

  it_behaves_like "a portage adapter"

  it "advertises discount and fulfillment (both true) and identity (link_identity overridden)" do
    registry = Portage::Ucp::CapabilityRegistry.default
    advertised = registry.advertised(adapter).map(&:name)

    expect(advertised).to include("dev.ucp.shopping.discount", "dev.ucp.shopping.fulfillment",
                                  "dev.ucp.shopping.identity")
  end

  describe "#reorder" do
    def place_order(product_id:, quantity: 1)
      checkout = adapter.create_checkout(line_items: [{ product_id: product_id, quantity: quantity }],
                                         idempotency_key: "chk-#{product_id}-#{rand(1_000_000)}")
      completed = adapter.complete_checkout(checkout_id: checkout.id, payment_token: "tok",
                                            idempotency_key: "cmp-#{product_id}-#{rand(1_000_000)}")
      completed.order.id
    end

    it "returns nil for an unknown order id" do
      expect(adapter.reorder(order_id: "ord_nonexistent", idempotency_key: "k1")).to be_nil
    end

    it "hydrates a cart from a still-purchasable order" do
      order_id = place_order(product_id: existing_product_id, quantity: 2)

      result = adapter.reorder(order_id: order_id, idempotency_key: "reorder-1")

      expect(result.unavailable_items).to eq([])
      expect(result.cart.line_items.map { |li| [li.item.title, li.quantity] }).to eq([["Cold Brew", 2]])
    end

    it "drops a line item whose product was discontinued since purchase, reporting why" do
      adapter.seed_product(ProductFactory.build(id: "prod_2", title: "Espresso", price_minor: 300))
      order_id = place_order(product_id: "prod_2")
      adapter.instance_variable_get(:@products).delete("prod_2")

      result = adapter.reorder(order_id: order_id, idempotency_key: "reorder-2")

      expect(result.cart.line_items).to eq([])
      expect(result.unavailable_items.map(&:title)).to eq(["Espresso"])
      expect(result.unavailable_items.first.reason).to eq("discontinued")
    end

    it "dedupes a repeated idempotency_key rather than hydrating a second cart" do
      order_id = place_order(product_id: existing_product_id)

      first = adapter.reorder(order_id: order_id, idempotency_key: "reorder-3")
      second = adapter.reorder(order_id: order_id, idempotency_key: "reorder-3")

      expect(second.cart.id).to eq(first.cart.id)
    end
  end

  it "links an oauth token to a stable identity" do
    first = adapter.link_identity(oauth_token: "tok_abc")
    second = adapter.link_identity(oauth_token: "tok_abc")

    expect(first).to eq(second)
    expect(first.subject).to match(/\Auser_[0-9a-f]{12}\z/)
  end

  # §23 step 3: Dispatcher threads its logger and a per-call correlation_id
  # onto the adapter (Support::CheckoutState.with_observability, scoped to
  # this call only) so a checkout_state_transition event carries the same id
  # as the tool_called event that triggered it, without checkout methods
  # taking a correlation_id: kwarg (a breaking change to the Adapter
  # contract).
  it "emits a checkout_state_transition event through the correlation id Dispatcher was given (§12, §23)" do
    io = StringIO.new
    logger = Logger.new(io).tap { |l| l.formatter = proc { |_severity, _time, _progname, msg| "#{msg}\n" } }
    dispatcher = Portage::Ucp::Dispatcher.new(adapter: adapter, logger: logger)

    dispatcher.call(capability: "dev.ucp.shopping.checkout", action: "create_checkout",
                    arguments: { line_items: [{ product_id: "prod_1", quantity: 1 }], idempotency_key: "k1" },
                    correlation_id: "corr-123")

    logged = JSON.parse(io.string.lines.last)
    expect(logged["event"]).to eq("checkout_state_transition")
    expect(logged["status"]).to eq("incomplete")
    expect(logged["correlation_id"]).to eq("corr-123")
  end
end
