require "spec_helper"
require "tmpdir"

RSpec.describe Portage::Ucp::Support::OrderLedger do
  around { |example| Dir.mktmpdir { |dir| @path = File.join(dir, "nested", "orders.json") and example.run } }

  def ledger = described_class.new(path: @path)

  def build_order(id: "ord_1")
    item = Portage::Ucp::Item.new(id: "prod_1", title: "Cold Brew", price: 500)
    line_item = Portage::Ucp::OrderLineItem.new(
      id: "li_1", item: item, quantity: { total: 1, fulfilled: 0 },
      totals: [Portage::Ucp::Total.new(type: "total", amount: 500)], status: "unfulfilled"
    )
    Portage::Ucp::Order.new(id: id, checkout_id: "chk_1", permalink_url: "https://example.com/o/#{id}",
                            line_items: [line_item], fulfillment: Portage::Ucp::Fulfillment.new,
                            currency: "USD", totals: [Portage::Ucp::Total.new(type: "total", amount: 500)])
  end

  it "records an order snapshot readable back from a fresh instance (simulating a new process)" do
    order = build_order
    ledger.record(idempotency_key: "k1", order: order)

    fresh = described_class.new(path: @path)
    record = fresh.find("ord_1")
    expect(record["idempotency_key"]).to eq("k1")
    expect(record["order"]).to eq(order.to_wire_h)
  end

  it "keeps snapshots for different order ids independent" do
    ledger.record(idempotency_key: "k1", order: build_order(id: "ord_1"))
    ledger.record(idempotency_key: "k2", order: build_order(id: "ord_2"))

    expect(ledger.find("ord_1")["idempotency_key"]).to eq("k1")
    expect(ledger.find("ord_2")["idempotency_key"]).to eq("k2")
  end

  it "chmods the file 0600 on write" do
    ledger.record(idempotency_key: "k1", order: build_order)

    expect(File.stat(@path).mode & 0o777).to eq(0o600)
  end

  it "returns nil for an order id never recorded" do
    expect(ledger.find("nope")).to be_nil
  end

  it "enumerates every recorded snapshot via #each_record/#all" do
    ledger.record(idempotency_key: "k1", order: build_order(id: "ord_1"))
    ledger.record(idempotency_key: "k2", order: build_order(id: "ord_2"))

    expect(ledger.all.map { |r| r["idempotency_key"] }).to contain_exactly("k1", "k2")
  end

  it "returns an Enumerator from #each_record without a block" do
    ledger.record(idempotency_key: "k1", order: build_order)

    expect(ledger.each_record).to be_a(Enumerator)
  end

  describe "pluggable store (§33)" do
    let(:memory_store) do
      Class.new(Portage::Ucp::Support::OrderLedger::Store) do
        def initialize
          @records = {}
        end

        def record(order_id, record) = @records[order_id] = record
        def find(order_id) = @records[order_id]
      end.new
    end

    it "routes record/find through an injected store without touching a file" do
      ledger = described_class.new(store: memory_store)

      ledger.record(idempotency_key: "k1", order: build_order(id: "ord_1"))

      expect(ledger.find("ord_1")["idempotency_key"]).to eq("k1")
      expect(File.exist?(@path)).to be(false)
    end

    it "raises NotImplementedError from the abstract Store" do
      expect { Portage::Ucp::Support::OrderLedger::Store.new.record("x", {}) }
        .to raise_error(Portage::Ucp::NotImplementedError)
    end
  end
end
