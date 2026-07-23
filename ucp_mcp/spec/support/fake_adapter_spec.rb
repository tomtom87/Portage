require "spec_helper"
require "support/fake_adapter"

RSpec.describe UcpMcp::Support::FakeAdapter do
  subject(:adapter) { described_class.new }
  let(:product) do
    UcpMcp::Product.new(id: "prod_1", title: "Cold Brew", description: "desc",
                         price: UcpMcp::Money.new(amount_minor: 500, currency: "USD"),
                         available: true, variants: [], url: "https://example.com/prod_1")
  end

  before { adapter.seed_product(product) }

  it "adds a line item to a cart" do
    cart = adapter.add_line_item(cart_id: "cart_1", product_id: "prod_1", quantity: 2, idempotency_key: "k1")
    expect(cart.line_items.size).to eq(1)
    expect(cart.subtotal.amount_minor).to eq(1000)
  end

  it "dedups a repeated idempotency key instead of re-running the mutation" do
    first = adapter.add_line_item(cart_id: "cart_1", product_id: "prod_1", quantity: 1, idempotency_key: "same-key")
    second = adapter.add_line_item(cart_id: "cart_1", product_id: "prod_1", quantity: 1, idempotency_key: "same-key")
    expect(second).to equal(first)
    expect(second.line_items.size).to eq(1)
  end

  it "searches the catalog by title" do
    results = adapter.search_catalog(query: "brew", limit: 10)
    expect(results).to eq([product])
  end

  it "creates and completes a checkout" do
    cart = adapter.add_line_item(cart_id: "cart_1", product_id: "prod_1", quantity: 1, idempotency_key: "k2")
    checkout = adapter.create_checkout(line_items: cart.line_items, idempotency_key: "k3")
    expect(checkout.status).to eq("pending")

    completed = adapter.complete_checkout(checkout_id: checkout.id, payment_token: "tok_test", idempotency_key: "k4")
    expect(completed.status).to eq("completed")
  end
end
