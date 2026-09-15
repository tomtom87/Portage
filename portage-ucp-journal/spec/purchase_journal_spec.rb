require "spec_helper"

RSpec.describe Portage::Ucp::Journal::PurchaseJournal do
  let(:store) { instance_double(Portage::Ucp::Journal::Store, append: nil) }
  let(:journal) { described_class.new(store: store, clock: -> { Time.utc(2026, 9, 15, 12, 0, 0) }) }

  def line_item(product_id:, quantity:, amount:)
    Portage::Ucp::LineItem.new(
      id: "line_#{product_id}",
      item: Portage::Ucp::Item.new(id: product_id, title: product_id, price: amount),
      quantity: quantity,
      totals: [Portage::Ucp::Total.new(type: "total", amount: amount)]
    )
  end

  def checkout(line_items:, order_id: "order_1")
    Portage::Ucp::Checkout.new(
      id: "checkout_1", status: "completed", line_items: line_items, currency: "USD",
      totals: [Portage::Ucp::Total.new(type: "total", amount: 3000)], links: [],
      order: order_id && Portage::Ucp::OrderConfirmation.new(id: order_id, permalink_url: "https://example.com/o/1")
    )
  end

  it "writes one entry per line item" do
    settled = checkout(line_items: [
                         line_item(product_id: "sku_1", quantity: 2, amount: 2000),
                         line_item(product_id: "sku_2", quantity: 1, amount: 1000)
                       ])

    entries = journal.record_checkout(shop: "example.myshopify.com", source: "adapter:shopify", checkout: settled,
                                      idempotency_key: "idem_1")

    expect(entries).to eq([
                            { "shop" => "example.myshopify.com", "source" => "adapter:shopify",
                              "product_id" => "sku_1", "quantity" => 2, "amount" => 2000, "currency" => "USD",
                              "order_id" => "order_1", "idempotency_key" => "idem_1",
                              "recorded_at" => "2026-09-15T12:00:00Z" },
                            { "shop" => "example.myshopify.com", "source" => "adapter:shopify",
                              "product_id" => "sku_2", "quantity" => 1, "amount" => 1000, "currency" => "USD",
                              "order_id" => "order_1", "idempotency_key" => "idem_1",
                              "recorded_at" => "2026-09-15T12:00:00Z" }
                          ])
  end

  it "appends every entry to the store" do
    settled = checkout(line_items: [line_item(product_id: "sku_1", quantity: 1, amount: 1000)])

    expect(store).to receive(:append).once.with(hash_including("product_id" => "sku_1"))

    journal.record_checkout(shop: "shop", source: "native_ucp", checkout: settled, idempotency_key: "idem_1")
  end

  it "records a nil order_id rather than raising when the checkout has no order confirmation" do
    settled = checkout(line_items: [line_item(product_id: "sku_1", quantity: 1, amount: 1000)], order_id: nil)

    entries = journal.record_checkout(shop: "shop", source: "native_ucp", checkout: settled,
                                      idempotency_key: "idem_1")

    expect(entries.first["order_id"]).to be_nil
  end

  it "delegates #each_record and #all to the store" do
    real_store = Portage::Ucp::Journal::FileStore.new(path: Dir::Tmpname.create("journal") { |p| p })
    journal = described_class.new(store: real_store)
    settled = checkout(line_items: [line_item(product_id: "sku_1", quantity: 1, amount: 1000)])

    journal.record_checkout(shop: "shop", source: "native_ucp", checkout: settled, idempotency_key: "idem_1")

    expect(journal.all.map { |e| e["product_id"] }).to eq(["sku_1"])
  end
end
