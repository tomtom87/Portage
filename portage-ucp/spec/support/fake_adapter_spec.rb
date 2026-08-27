require "spec_helper"
require "support/fake_adapter"
require "support/product_factory"

RSpec.describe Portage::Ucp::Support::FakeAdapter do
  subject(:adapter) { described_class.new }
  let(:product) { ProductFactory.build(id: "prod_1", title: "Cold Brew", price_minor: 500) }

  before { adapter.seed_product(product) }

  it "creates a cart from the requested line items" do
    cart = adapter.create_cart(line_items: [{ product_id: "prod_1", quantity: 2 }], idempotency_key: "k1")
    expect(cart.line_items.size).to eq(1)
    expect(cart.totals.find { |t| t.type == "total" }.amount).to eq(1000)
  end

  it "dedups a repeated idempotency key instead of re-running the mutation" do
    first = adapter.create_cart(line_items: [{ product_id: "prod_1", quantity: 1 }], idempotency_key: "same-key")
    second = adapter.create_cart(line_items: [{ product_id: "prod_1", quantity: 1 }], idempotency_key: "same-key")
    expect(second).to equal(first)
    expect(second.line_items.size).to eq(1)
  end

  it "replaces a cart's line items wholesale on update" do
    cart = adapter.create_cart(line_items: [{ product_id: "prod_1", quantity: 1 }], idempotency_key: "k2")
    updated = adapter.update_cart(cart_id: cart.id, line_items: [{ product_id: "prod_1", quantity: 3 }],
                                  idempotency_key: "k3")
    expect(updated.line_items.first.quantity).to eq(3)
  end

  it "cancels a cart, clearing its line items" do
    cart = adapter.create_cart(line_items: [{ product_id: "prod_1", quantity: 1 }], idempotency_key: "k4")
    canceled = adapter.cancel_cart(cart_id: cart.id, idempotency_key: "k5")
    expect(canceled.line_items).to eq([])
  end

  it "searches the catalog by title" do
    results = adapter.search_catalog(query: "brew", limit: 10)
    expect(results.products).to eq([product])
  end

  it "creates, gets, and completes a checkout" do
    checkout = adapter.create_checkout(line_items: [{ product_id: "prod_1", quantity: 1 }], idempotency_key: "k6")
    expect(checkout.status).to eq("incomplete")
    expect(adapter.get_checkout(checkout_id: checkout.id)).to eq(checkout)

    completed = adapter.complete_checkout(checkout_id: checkout.id, payment_token: "tok_test", idempotency_key: "k7")
    expect(completed.status).to eq("completed")
  end

  it "links a completed checkout to a fetchable order via Checkout#order" do
    checkout = adapter.create_checkout(line_items: [{ product_id: "prod_1", quantity: 1 }], idempotency_key: "k10")
    completed = adapter.complete_checkout(checkout_id: checkout.id, payment_token: "tok_test", idempotency_key: "k11")

    expect(completed.order.id).not_to be_empty
    order = adapter.get_order(order_id: completed.order.id)
    expect(order.checkout_id).to eq(checkout.id)
    expect(order.permalink_url).to eq(completed.order.permalink_url)
  end

  it "cancels a checkout" do
    checkout = adapter.create_checkout(line_items: [{ product_id: "prod_1", quantity: 1 }], idempotency_key: "k8")
    canceled = adapter.cancel_checkout(checkout_id: checkout.id, idempotency_key: "k9")
    expect(canceled.status).to eq("canceled")
  end
end
