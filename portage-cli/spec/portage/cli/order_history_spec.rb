require "spec_helper"
require "tmpdir"

RSpec.describe Portage::Cli::OrderHistory do
  around { |example| Dir.mktmpdir { |dir| @dir = dir and example.run } }

  let(:journal_store) { Portage::Ucp::Journal::FileStore.new(path: File.join(@dir, "journal.jsonl")) }
  let(:journal) { Portage::Ucp::Journal::PurchaseJournal.new(store: journal_store) }
  let(:order_ledger) { Portage::Ucp::Support::OrderLedger.new(path: File.join(@dir, "orders.json")) }
  let(:history_path) { File.join(@dir, "history.json") }
  let(:transaction_log) { Portage::Ucp::Support::TransactionLog.new(path: File.join(@dir, "transactions.json")) }
  let(:order_history) do
    described_class.new(journal: journal, order_ledger: order_ledger, history: history,
                        transaction_log: transaction_log)
  end
  let(:history) { Portage::Cli::History.new(path: history_path, now: Time.utc(2026, 10, 3)) }

  def journal_row(order_id:, shop:, product_id:, at:, key: "key-#{order_id}", amount: 500, quantity: 1)
    journal_store.append("shop" => shop, "source" => "native_ucp", "product_id" => product_id, "quantity" => quantity,
                         "amount" => amount, "currency" => "USD", "order_id" => order_id, "idempotency_key" => key,
                         "recorded_at" => at)
  end

  def ledger_order(id, adjustments: [])
    order = Portage::Ucp::OrderConfirmation.new(id: id, permalink_url: "https://shop-a.example/o/#{id}")
    order_ledger.record(idempotency_key: "key-#{id}", order: order)
    stored = order_ledger.find(id)
    order_ledger.instance_variable_get(:@store)
                .record(id, stored.merge("order" => stored["order"].merge("adjustments" => adjustments)))
  end

  def history_purchase(url:, outcome:, checkout_id:, items: [], at: Time.utc(2026, 10, 3))
    checkout_url = "https://#{URI.parse(url).host}/c/#{checkout_id}"
    Portage::Cli::History.new(path: history_path, now: at)
                         .record_purchase(url: url, query: "q", outcome: outcome, message: "m", total: 900,
                                          checkout_id: checkout_id, checkout_url: checkout_url, currency: "USD",
                                          items: items)
  end

  it "is empty when nothing has been recorded" do
    expect(order_history.call).to eq([])
  end

  it "merges journal, ledger and history newest first, deduping history purchases the journal covers" do
    journal_row(order_id: "ord_1", shop: "shop-a.example", product_id: "p1", at: "2026-10-01T10:00:00Z")
    journal_row(order_id: "ord_1", shop: "shop-a.example", product_id: "p2", at: "2026-10-01T10:00:00Z", amount: 250)
    journal_row(order_id: "ord_2", shop: "shop-b.example", product_id: "p3", at: "2026-10-05T10:00:00Z")
    ledger_order("ord_1")
    history_purchase(url: "https://shop-a.example", outcome: "purchased", checkout_id: "chk_1",
                     at: Time.utc(2026, 10, 1), items: [{ "id" => "p1", "title" => "Cold Brew", "quantity" => 1 }])
    transaction_log.reserve(idempotency_key: "key-ord_1", checkout_id: "chk_1", payment_token_ref: nil)
    history_purchase(url: "https://shop-c.example", outcome: "purchased", checkout_id: nil, at: Time.utc(2026, 10, 3))

    entries = order_history.call

    expect(entries.map { |e| [e["source"], e["order_id"], e["shop"]] })
      .to eq([["journal", "ord_2", "shop-b.example"], ["history", nil, "shop-c.example"],
              ["journal", "ord_1", "shop-a.example"]])
    ord1 = entries.last
    expect(ord1).to include("total" => 750, "currency" => "USD", "permalink_url" => "https://shop-a.example/o/ord_1",
                            "recorded_at" => "2026-10-01T10:00:00Z")
    expect(ord1["items"]).to eq([{ "product_id" => "p1", "title" => "Cold Brew", "quantity" => 1, "amount" => 500 },
                                 { "product_id" => "p2", "title" => nil, "quantity" => 1, "amount" => 250 }])
  end

  it "lists history purchases and hand-offs when there is no journal" do
    history_purchase(url: "https://shop-a.example", outcome: "purchased", checkout_id: nil)
    history_purchase(url: "https://shop-b.example", outcome: "policy_blocked", checkout_id: "chk_2")
    history_purchase(url: "https://shop-c.example", outcome: "dry_run", checkout_id: "chk_3")
    transaction_log.reserve(idempotency_key: "k2", checkout_id: "chk_2", payment_token_ref: nil, settled_by: "shopper")

    entries = order_history.call

    expect(entries.map { |e| [e["source"], e["shop"], e["outcome"]] })
      .to contain_exactly(["history", "shop-a.example", "purchased"], ["history", "shop-b.example", "policy_blocked"])
  end

  it "never links a history purchase without a checkout id to a transaction" do
    journal_row(order_id: "ord_1", shop: "shop-a.example", product_id: "p1", at: "2026-10-01T10:00:00Z")
    transaction_log.reserve(idempotency_key: "key-ord_1", checkout_id: nil, payment_token_ref: nil)
    history_purchase(url: "https://shop-c.example", outcome: "purchased", checkout_id: nil)

    expect(order_history.call.map { |e| e["source"] }).to contain_exactly("journal", "history")
  end

  it "reads adjustments from the ledger" do
    journal_row(order_id: "ord_1", shop: "shop-a.example", product_id: "p1", at: "2026-10-01T10:00:00Z")
    ledger_order("ord_1", adjustments: [{ "id" => "adj_1", "type" => "refund", "status" => "pending" }])

    expect(order_history.call.first["adjustments"]).to eq([{ "id" => "adj_1", "type" => "refund",
                                                             "status" => "pending" }])
  end

  describe "query and limit" do
    before do
      journal_row(order_id: "ORD_1", shop: "Shop-A.example", product_id: "SKU-1", at: "2026-10-01T10:00:00Z")
      journal_row(order_id: "ord_2", shop: "shop-b.example", product_id: "sku-2", at: "2026-10-02T10:00:00Z")
      history_purchase(url: "https://shop-c.example", outcome: "purchased", checkout_id: nil,
                       items: [{ "id" => "x9", "title" => "Hario Kettle", "quantity" => 1 }])
    end

    it "matches host, product id, item title and order id case-insensitively" do
      expect(order_history.call(query: "SHOP-a").map { |e| e["order_id"] }).to eq(["ORD_1"])
      expect(order_history.call(query: "sku-1").map { |e| e["order_id"] }).to eq(["ORD_1"])
      expect(order_history.call(query: "kettle").map { |e| e["shop"] }).to eq(["shop-c.example"])
      expect(order_history.call(query: "ORD_2").map { |e| e["order_id"] }).to eq(["ord_2"])
    end

    it "applies the limit after filtering and sorting" do
      expect(order_history.call(limit: 1).map { |e| e["shop"] }).to eq(["shop-c.example"])
      expect(order_history.call(query: "sku", limit: 1).map { |e| e["order_id"] }).to eq(["ord_2"])
    end
  end
end
