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

  describe "post-purchase adjustments (Phase 3)" do
    def adjustment(id:, type:, status:)
      Portage::Ucp::Adjustment.new(id: id, type: type, occurred_at: "2026-10-13T00:00:00Z", status: status)
    end

    # Upstream's current view of the order: same id, adjustments as given,
    # and deliberately different purchase facts — proves those are never
    # read back into the snapshot.
    def upstream(adjustments)
      order = build_order
      Portage::Ucp::Order.new(**order.to_h, currency: "EUR", adjustments: adjustments,
                                            totals: [Portage::Ucp::Total.new(type: "total", amount: 1)])
    end

    let(:adapter) { instance_double(Portage::Ucp::Adapter) }

    before { ledger.record(idempotency_key: "k1", order: build_order) }

    it "records adjustments onto the existing snapshot, leaving purchase facts untouched" do
      ledger.record_adjustments(upstream([adjustment(id: "adj_1", type: "refund", status: "completed")]))

      stored = ledger.find("ord_1")["order"]
      expect(stored.except("adjustments")).to eq(build_order.to_wire_h)
      expect(stored["adjustments"].map { |a| a["id"] }).to eq(["adj_1"])
    end

    it "skips an order with no purchase snapshot rather than backfilling one" do
      orphan = Portage::Ucp::Order.new(**build_order(id: "ord_x").to_h,
                                       adjustments: [adjustment(id: "adj_1", type: "refund", status: "completed")])

      expect(ledger.record_adjustments(orphan)).to be_nil
      expect(ledger.find("ord_x")).to be_nil
    end

    it "refresh merges a newly-appeared dispute without altering stored line-item totals" do
      allow(adapter).to receive(:get_order).with(order_id: "ord_1")
                                           .and_return(upstream([adjustment(id: "dsp_1", type: "dispute",
                                                                            status: "pending")]))
      before = ledger.find("ord_1")["order"]

      ledger.refresh("ord_1", adapter: adapter)

      stored = ledger.find("ord_1")["order"]
      expect(stored["line_items"]).to eq(before["line_items"])
      expect(stored.except("adjustments")).to eq(before)
      expect(stored["adjustments"]).to eq([{ "id" => "dsp_1", "type" => "dispute",
                                             "occurred_at" => "2026-10-13T00:00:00Z", "status" => "pending" }])
    end

    it "refresh reflects a pending return flipping to completed upstream" do
      ledger.record_adjustments(upstream([adjustment(id: "ret_1", type: "return", status: "pending")]))
      allow(adapter).to receive(:get_order)
        .and_return(upstream([adjustment(id: "ret_1", type: "return", status: "completed")]))

      ledger.refresh("ord_1", adapter: adapter)

      expect(ledger.find("ord_1")["order"]["adjustments"].map { |a| a["status"] }).to eq(["completed"])
    end

    it "refresh is a no-op when upstream no longer returns the order" do
      allow(adapter).to receive(:get_order).and_return(nil)

      expect(ledger.refresh("ord_1", adapter: adapter)).to be_nil
      expect(ledger.find("ord_1")["order"]).to eq(build_order.to_wire_h)
    end

    it "lists exactly the pending adjustments across orders, with their order id" do
      ledger.record(idempotency_key: "k2", order: build_order(id: "ord_2"))
      ledger.record_adjustments(upstream([adjustment(id: "ref_1", type: "refund", status: "completed"),
                                          adjustment(id: "ret_1", type: "return", status: "pending")]))
      ledger.record_adjustments(Portage::Ucp::Order.new(
                                  **build_order(id: "ord_2").to_h,
                                  adjustments: [adjustment(id: "dsp_1", type: "chargeback", status: "pending"),
                                                adjustment(id: "ret_2", type: "return", status: "failed")]
                                ))

      expect(ledger.unresolved.map { |u| [u["order_id"], u["adjustment"]["id"]] })
        .to contain_exactly(%w[ord_1 ret_1], %w[ord_2 dsp_1])
    end
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
