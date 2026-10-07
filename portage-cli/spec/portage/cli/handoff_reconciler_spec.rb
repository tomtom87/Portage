require "spec_helper"

RSpec.describe Portage::Cli::HandoffReconciler do
  let(:transaction_log) { Portage::Ucp::Support::TransactionLog.new }
  let(:order_ledger) { instance_double(Portage::Ucp::Support::OrderLedger, record: nil) }
  let(:journal) { instance_double(Portage::Ucp::Journal::PurchaseJournal, record_checkout: nil) }
  let(:notifier) { instance_double(Portage::Cli::Notifier, call: nil) }

  def reconciler(spend_mode: "block", handoff_only: nil)
    described_class.new(transaction_log: transaction_log, order_ledger: order_ledger, journal: journal,
                        notifier: notifier, spend_mode: spend_mode, handoff_only: handoff_only)
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

  # A real UCP server rejects any call without meta.ucp-agent.profile
  # (MissingAgentProfileError); before this, every live reconcile settled
  # nothing and read as "not found" (design-log §55).
  it "sends the agent profile on get_checkout" do
    reserve_pending
    session = stub_checkout({ "id" => "chk_1", "status" => "incomplete" })

    reconciler.call(transaction_log.find("portage-buy:shop.example:chk_1"))

    expect(session).to have_received(:get_checkout)
      .with(checkout_id: "chk_1", meta: { agent_profile: Portage::Cli::AgentProfileUrl.resolve })
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

  # Defense in depth (docs/plans/buy-skill-and-local-browser.md Phase 5):
  # Buy's `handoff_only` outcome never actually reserves a TransactionLog
  # record (no checkout was ever built), so this record shouldn't exist in
  # practice — but #reconnect is the one place every reconcile path fetches
  # a store again, so it's guarded here too.
  describe "a record whose store_url is hand-off only" do
    it "never sends a request, and settles nothing" do
      Portage::Cli::Config.load.set("handoff_only_hosts", ["amazon.co.uk"])
      reserve_pending(store_url: "https://www.amazon.co.uk")
      expect(Portage::Ucp::Client).not_to receive(:discover)

      result = reconciler.call(transaction_log.find("portage-buy:shop.example:chk_1"))

      expect(result.settled).to be false
      expect(result.note).to include("hand-off only")
      expect(a_request(:any, /.*/)).not_to have_been_made
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

    # Shape seen live on Shopify right after cancel_checkout (design-log §55).
    it "notes a store's checkout_not_found error by its message, not the whole envelope" do
      reserve_pending
      body = { "ucp" => { "status" => "error" }, "continue_url" => "https://shop.example/",
               "messages" => [{ "type" => "error", "code" => "checkout_not_found",
                                "content" => "The requested checkout does not exist", "severity" => "unrecoverable" }] }
      session = instance_double(Portage::Ucp::Client::Session)
      allow(session).to receive(:get_checkout)
        .and_raise(Portage::Ucp::Client::ServerError.new(JSON.generate(body), payload: body))
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session)

      result = reconciler.call(transaction_log.find("portage-buy:shop.example:chk_1"))

      expect(result.status).to eq("pending")
      expect(result.note).to eq("The requested checkout does not exist")
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
      allow(session).to receive(:get_order).with(order_id: "ord_1", meta: { agent_profile: String })
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

  # Design-log §55: an adapter-backed store tracked checkout status only in
  # the process that created the checkout, so reconcile (always a new
  # process, reconnecting through AdapterSession's loopback) could never see
  # `completed`. This runs the real loopback against a fresh adapter whose
  # cart is gone and whose platform reports the order, end to end.
  describe "an adapter store whose platform reports the order (design-log §55)" do
    let(:order) do
      Portage::Ucp::Order.new(
        id: "ord_9", checkout_id: "chk_1", permalink_url: "https://shop.example/orders/9",
        line_items: [Portage::Ucp::OrderLineItem.new(
          id: "li_1", item: Portage::Ucp::Item.new(id: "p1", title: "Lamp", price: 1250),
          quantity: { original: 2, total: 2, fulfilled: 0 }, totals: Portage::Ucp::Support::Totals.line(2500),
          status: "processing"
        )],
        fulfillment: Portage::Ucp::Fulfillment.new, currency: "USD",
        totals: Portage::Ucp::Support::Totals.summary(subtotal: 2500, total: 2500)
      )
    end
    let(:adapter_class) do
      Class.new(Portage::Ucp::Adapter) do
        include Portage::Ucp::Support::CheckoutState

        def initialize(order)
          super()
          @order = order
        end

        # The platform already dropped the cart, as BigCommerce/Magento do.
        def get_checkout(checkout_id:) = checkout_from_platform_order(checkout_id)
        def get_order(order_id:) = (@order if order_id == @order.id)

        private

        def platform_checkout_order(_checkout_id) = @order
      end
    end

    it "settles complete with the order's amount and snapshots the order" do
      reserve_pending
      allow(Portage::Ucp::Client).to receive(:discover).and_raise(Portage::Ucp::Client::DiscoveryError, "no manifest")
      allow(Portage::Cli::AdapterSession).to receive(:call) do
        Portage::Ucp::Client.for_adapter(adapter_class.new(order), authenticator: Portage::Cli::PermissiveAuthenticator.new)
      end

      result = reconciler.call(transaction_log.find("portage-buy:shop.example:chk_1"))

      expect(result.to_h).to include(settled: true, status: "complete", order_id: "ord_9", amount: 2500,
                                     currency: "USD")
      expect(order_ledger).to have_received(:record).with(idempotency_key: "portage-buy:shop.example:chk_1",
                                                          order: having_attributes(id: "ord_9"))
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
