require "spec_helper"

RSpec.describe Portage::Cli::HandoffReconciler do
  let(:transaction_log) { Portage::Ucp::Support::TransactionLog.new }
  let(:order_ledger) { instance_double(Portage::Ucp::Support::OrderLedger, record: nil) }
  let(:journal) { instance_double(Portage::Ucp::Journal::PurchaseJournal, record_checkout: nil) }
  let(:notifier) { instance_double(Portage::Cli::Notifier, call: nil) }

  def reconciler(spend_mode: "block")
    described_class.new(transaction_log: transaction_log, order_ledger: order_ledger, journal: journal,
                        notifier: notifier, spend_mode: spend_mode)
  end

  def reserve_pending(checkout_id: "chk_1", store_url: "https://shop.example", expires_at: nil,
                      handoff_reason: "requires_escalation")
    transaction_log.reserve(idempotency_key: "portage-buy:shop.example:#{checkout_id}", checkout_id: checkout_id,
                            payment_token_ref: nil, shop: "shop.example", settled_by: "shopper",
                            handoff_reason: handoff_reason, store_url: store_url, expires_at: expires_at)
  end

  def stub_checkout(checkout)
    session = instance_double(Portage::Ucp::Client::Session, get_checkout: checkout)
    allow(Portage::Ucp::Client).to receive(:discover).and_return(session)
    session
  end

  describe "records this isn't for" do
    it "no-ops on an already-settled record" do
      transaction_log.reserve(idempotency_key: "k1", checkout_id: "chk_1", payment_token_ref: nil,
                              settled_by: "shopper")
      transaction_log.complete(idempotency_key: "k1", status: "complete")

      result = reconciler.call(transaction_log.find("k1"))

      expect(result.settled).to be false
      expect(result.note).to eq("already settled")
    end

    it "no-ops on a dispatcher crash-evidence pending record (settled_by nil)" do
      transaction_log.reserve(idempotency_key: "k1", checkout_id: "chk_1", payment_token_ref: nil)

      result = reconciler.call(transaction_log.find("k1"))

      expect(result.settled).to be false
      expect(result.note).to eq("not a shopper handoff")
    end
  end

  describe "settling from the store's own status" do
    it "settles complete on a completed status, using the store's own total, not the handoff-time snapshot" do
      reserve_pending
      checkout = { "id" => "chk_1", "status" => "completed", "currency" => "USD",
                   "totals" => [{ "type" => "total", "amount" => 4200 }] }
      stub_checkout(checkout)

      result = reconciler.call(transaction_log.find("portage-buy:shop.example:chk_1"))

      expect(result.settled).to be true
      expect(result.status).to eq("complete")
      expect(result.amount).to eq(4200)
      record = transaction_log.find("portage-buy:shop.example:chk_1")
      expect(record["status"]).to eq("complete")
      expect(record["amount"]).to eq(4200)
    end

    it "settles failed on a canceled status" do
      reserve_pending
      stub_checkout({ "id" => "chk_1", "status" => "canceled" })

      result = reconciler.call(transaction_log.find("portage-buy:shop.example:chk_1"))

      expect(result.status).to eq("failed")
      expect(result.resolution).to be_nil
    end

    it "stays pending on an in-progress status" do
      reserve_pending
      stub_checkout({ "id" => "chk_1", "status" => "ready_for_complete" })

      result = reconciler.call(transaction_log.find("portage-buy:shop.example:chk_1"))

      expect(result.settled).to be false
      expect(transaction_log.find("portage-buy:shop.example:chk_1")["status"]).to eq("pending")
    end

    it "carries the store's own raw status while pending, for HandoffWaiter's NDJSON events" do
      reserve_pending
      stub_checkout({ "id" => "chk_1", "status" => "ready_for_complete" })

      result = reconciler.call(transaction_log.find("portage-buy:shop.example:chk_1"))

      expect(result.checkout_status).to eq("ready_for_complete")
    end

    it "settles failed with resolution expired once expires_at has passed, even mid-progress" do
      reserve_pending(expires_at: (Time.now - 3600).utc.iso8601)
      stub_checkout({ "id" => "chk_1", "status" => "ready_for_complete" })

      result = reconciler.call(transaction_log.find("portage-buy:shop.example:chk_1"))

      expect(result.status).to eq("failed")
      expect(result.resolution).to eq("expired")
    end

    it "stays pending on a not-found checkout before expiry" do
      reserve_pending
      stub_checkout(nil)

      result = reconciler.call(transaction_log.find("portage-buy:shop.example:chk_1"))

      expect(result.settled).to be false
    end

    it "settles failed with resolution unknown on a not-found checkout past expiry" do
      reserve_pending(expires_at: (Time.now - 3600).utc.iso8601)
      stub_checkout(nil)

      result = reconciler.call(transaction_log.find("portage-buy:shop.example:chk_1"))

      expect(result.status).to eq("failed")
      expect(result.resolution).to eq("unknown")
    end

    it "treats a transport error the same as not-found" do
      reserve_pending(expires_at: (Time.now - 3600).utc.iso8601)
      stub_request(:get, "https://shop.example/").to_return(status: 500)
      allow(Portage::Ucp::Client).to receive(:discover).and_raise(Portage::Ucp::Client::DiscoveryError, "boom")

      result = reconciler.call(transaction_log.find("portage-buy:shop.example:chk_1"))

      expect(result.status).to eq("failed")
      expect(result.resolution).to eq("unknown")
    end

    it "stays pending with a reconnect error when the store can't be reached at all and isn't expired" do
      reserve_pending
      stub_request(:get, "https://shop.example/").to_return(status: 500)
      allow(Portage::Ucp::Client).to receive(:discover).and_raise(Portage::Ucp::Client::DiscoveryError, "boom")

      result = reconciler.call(transaction_log.find("portage-buy:shop.example:chk_1"))

      expect(result.settled).to be false
    end
  end

  describe "idempotency" do
    it "is a no-op the second time it's called on an already-settled record" do
      reserve_pending
      stub_checkout({ "id" => "chk_1", "status" => "completed", "currency" => "USD", "totals" => [] })

      first = reconciler.call(transaction_log.find("portage-buy:shop.example:chk_1"))
      second = reconciler.call(transaction_log.find("portage-buy:shop.example:chk_1"))

      expect(first.settled).to be true
      expect(second.settled).to be false
      expect(second.note).to eq("already settled")
    end
  end

  describe "order snapshot + journal, on complete" do
    it "records the order and a journal entry when the checkout carries one" do
      reserve_pending
      order_ref = { "id" => "ord_1" }
      checkout = { "id" => "chk_1", "status" => "completed", "currency" => "USD", "totals" => [],
                   "order" => order_ref,
                   "line_items" => [{ "item" => { "id" => "p1" }, "quantity" => 1,
                                      "totals" => [{ "type" => "total", "amount" => 100 }] }] }
      session = stub_checkout(checkout)
      allow(session).to receive(:get_order).with(order_id: "ord_1")
                                           .and_return({ "id" => "ord_1", "checkout_id" => "chk_1" })

      result = reconciler.call(transaction_log.find("portage-buy:shop.example:chk_1"))

      expect(result.order_id).to eq("ord_1")
      expect(order_ledger).to have_received(:record).with(idempotency_key: "portage-buy:shop.example:chk_1",
                                                          order: having_attributes(id: "ord_1"))
      expect(journal).to have_received(:record_checkout)
    end

    it "never blocks the settle when get_order fails" do
      reserve_pending
      checkout = { "id" => "chk_1", "status" => "completed", "currency" => "USD", "totals" => [],
                   "order" => { "id" => "ord_1" }, "line_items" => [] }
      session = stub_checkout(checkout)
      allow(session).to receive(:get_order).and_raise(StandardError, "gateway down")

      result = reconciler.call(transaction_log.find("portage-buy:shop.example:chk_1"))

      expect(result.settled).to be true
      expect(result.status).to eq("complete")
    end
  end

  describe "spend-cap mode (Phase 2)" do
    it "counts a completed record toward caps under block (default)" do
      reserve_pending
      stub_checkout({ "id" => "chk_1", "status" => "completed", "currency" => "USD",
                      "totals" => [{ "type" => "total", "amount" => 100 }] })

      reconciler(spend_mode: "block").call(transaction_log.find("portage-buy:shop.example:chk_1"))

      record = transaction_log.find("portage-buy:shop.example:chk_1")
      expect(record["counts_toward_caps"]).to be true
    end

    it "excludes a completed record from caps under warn" do
      reserve_pending
      stub_checkout({ "id" => "chk_1", "status" => "completed", "currency" => "USD",
                      "totals" => [{ "type" => "total", "amount" => 100 }] })

      reconciler(spend_mode: "warn").call(transaction_log.find("portage-buy:shop.example:chk_1"))

      record = transaction_log.find("portage-buy:shop.example:chk_1")
      expect(record["counts_toward_caps"]).to be false
      expect(transaction_log.completed_since(Time.now - 3600, shop: "shop.example")).to eq([])
    end
  end

  describe "default notifier (Phase 3)" do
    it "defaults to ReconcileNotifier, not the plain webhook-only Notifier" do
      expect(described_class.new.send(:instance_variable_get, :@notifier)).to be_a(Portage::Cli::ReconcileNotifier)
    end
  end

  describe ".each_pending_shopper_record" do
    it "yields only pending, settled_by: shopper records" do
      reserve_pending(checkout_id: "chk_1")
      transaction_log.reserve(idempotency_key: "k-agent", checkout_id: "chk_2", payment_token_ref: nil,
                              shop: "shop.example")
      transaction_log.reserve(idempotency_key: "k-done", checkout_id: "chk_3", payment_token_ref: nil,
                              shop: "shop.example", settled_by: "shopper")
      transaction_log.complete(idempotency_key: "k-done", status: "complete")

      records = described_class.each_pending_shopper_record(transaction_log).to_a

      expect(records.map { |r| r["checkout_id"] }).to eq(["chk_1"])
    end
  end
end
