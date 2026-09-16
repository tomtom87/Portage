require "spec_helper"
require "portage/cli/console"
require "portage/ucp/journal"
require "tmpdir"

RSpec.describe Portage::Cli::Console do
  include described_class

  around { |example| Dir.mktmpdir { |dir| @dir = dir and example.run } }

  def transaction_log
    @transaction_log ||= Portage::Ucp::Support::TransactionLog.new(path: File.join(@dir, "transactions.json"))
  end

  def order_ledger
    @order_ledger ||= Portage::Ucp::Support::OrderLedger.new(path: File.join(@dir, "orders.json"))
  end

  def purchase_journal
    @purchase_journal ||= Portage::Ucp::Journal::PurchaseJournal.new(
      store: Portage::Ucp::Journal::FileStore.new(path: File.join(@dir, "journal.jsonl"))
    )
  end

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

  describe "#transactions / #find_transaction / #transactions_since" do
    it "lists every reserved transaction, optionally scoped by shop" do
      transaction_log.reserve(idempotency_key: "k1", checkout_id: "chk_1", payment_token_ref: "ref1", shop: "shop-a")
      transaction_log.reserve(idempotency_key: "k2", checkout_id: "chk_2", payment_token_ref: "ref2", shop: "shop-b")

      expect(transactions(transaction_log: transaction_log).map { |r| r["idempotency_key"] })
        .to contain_exactly("k1", "k2")
      expect(transactions(shop: "shop-a", transaction_log: transaction_log).map { |r| r["idempotency_key"] })
        .to eq(["k1"])
    end

    it "finds a single transaction by idempotency_key, or nil" do
      transaction_log.reserve(idempotency_key: "k1", checkout_id: "chk_1", payment_token_ref: "ref1")

      expect(find_transaction("k1", transaction_log: transaction_log)["checkout_id"]).to eq("chk_1")
      expect(find_transaction("missing", transaction_log: transaction_log)).to be_nil
    end

    it "passes through to TransactionLog#completed_since" do
      transaction_log.reserve(idempotency_key: "k1", checkout_id: "chk_1", payment_token_ref: "ref1", shop: "shop-a")
      transaction_log.complete(idempotency_key: "k1", status: "complete", amount: 100, currency: "USD")

      results = transactions_since(Time.now - 3600, shop: "shop-a", transaction_log: transaction_log)

      expect(results.map { |r| r["idempotency_key"] }).to eq(["k1"])
    end
  end

  describe "#orders / #find_order" do
    it "lists every recorded order snapshot" do
      order_ledger.record(idempotency_key: "k1", order: build_order(id: "ord_1"))
      order_ledger.record(idempotency_key: "k2", order: build_order(id: "ord_2"))

      expect(orders(order_ledger: order_ledger).map { |r| r["idempotency_key"] }).to contain_exactly("k1", "k2")
    end

    it "finds a single order snapshot by order id, or nil" do
      order_ledger.record(idempotency_key: "k1", order: build_order(id: "ord_1"))

      expect(find_order("ord_1", order_ledger: order_ledger)["idempotency_key"]).to eq("k1")
      expect(find_order("missing", order_ledger: order_ledger)).to be_nil
    end
  end

  describe "#journal" do
    def checkout_double
      total = Portage::Ucp::Total.new(type: "total", amount: 500)
      item = Portage::Ucp::Item.new(id: "prod_1", title: "Cold Brew", price: 500)
      line_item = Portage::Ucp::LineItem.new(id: "li_1", item: item, quantity: 1, totals: [total])
      order_confirmation = Struct.new(:id).new("ord_1")
      Struct.new(:currency, :line_items, :order).new("USD", [line_item], order_confirmation)
    end

    it "lists journal entries, optionally scoped by shop" do
      purchase_journal.record_checkout(shop: "shop-a", source: "native_ucp", idempotency_key: "idem_1",
                                       checkout: checkout_double)
      purchase_journal.record_checkout(shop: "shop-b", source: "native_ucp", idempotency_key: "idem_2",
                                       checkout: checkout_double)

      expect(journal(purchase_journal: purchase_journal).length).to eq(2)
      expect(journal(shop: "shop-a", purchase_journal: purchase_journal).map { |r| r["idempotency_key"] })
        .to eq(["idem_1"])
    end
  end

  it "redacts every result through Observability.redact, not just the top-level fields" do
    pii_ledger = Class.new(Portage::Ucp::Support::OrderLedger::Store) do
      def find(order_id)
        { "idempotency_key" => "k1", "order" => { "shipping" => { "email" => "ada@example.com" } } }
      end

      def each_record(&) = [find(nil)].each(&)
    end.new

    record = find_order("ord_1", order_ledger: Portage::Ucp::Support::OrderLedger.new(store: pii_ledger))

    expect(record["order"]["shipping"]["email"]).to eq("[REDACTED]")
  end
end
