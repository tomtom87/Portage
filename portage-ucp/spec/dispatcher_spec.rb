require "spec_helper"
require "tmpdir"
require "support/fake_adapter"
require "support/product_factory"

RSpec.describe Portage::Ucp::Dispatcher do
  around do |example|
    Dir.mktmpdir do |dir|
      @transactions_path = File.join(dir, "transactions.json")
      @orders_path = File.join(dir, "orders.json")
      example.run
    end
  end

  let(:adapter) { Portage::Ucp::Support::FakeAdapter.new }
  let(:transaction_log) { Portage::Ucp::Support::TransactionLog.new(path: @transactions_path) }
  let(:order_ledger) { Portage::Ucp::Support::OrderLedger.new(path: @orders_path) }
  let(:policy) { Portage::Ucp::Policy.new(path: File.join(Dir.mktmpdir, "policy.json")) }
  let(:confirmer) { Portage::Ucp::Confirmer::AutoApprove.new }
  let(:dispatcher) do
    described_class.new(adapter: adapter, transaction_log: transaction_log, order_ledger: order_ledger,
                        policy: policy, confirmer: confirmer, shop: "shop.example.com")
  end
  let(:product) { ProductFactory.build(id: "prod_1", title: "Cold Brew", price_minor: 500) }

  before { adapter.seed_product(product) }

  it "accepts a UCP-shaped request and routes it to the matching adapter method, wrapped in the ucp envelope" do
    response = dispatcher.call(capability: "dev.ucp.shopping.catalog", action: "search_catalog",
                               arguments: { query: "brew", limit: 10 })

    expect(response[:structuredContent]["products"]).to eq([product.to_wire_h])
    expect(response[:structuredContent]["ucp"]).to eq({ "version" => "2026-04-08" })
  end

  it "wraps the adapter's return value as both structuredContent and a text content block" do
    response = dispatcher.call(capability: "dev.ucp.shopping.catalog", action: "get_product",
                               arguments: { product_id: "prod_1" })

    expect(response[:structuredContent]["product"]).to eq(product.to_wire_h)
  end

  it "routes a cart mutation through, idempotency_key included, wrapped in the ucp envelope" do
    response = dispatcher.call(capability: "dev.ucp.shopping.cart", action: "create_cart",
                               arguments: { line_items: [{ product_id: "prod_1", quantity: 1 }],
                                            idempotency_key: "k1" })

    expect(response[:structuredContent]["line_items"].size).to eq(1)
    expect(response[:structuredContent]["ucp"]).to eq({ "version" => "2026-04-08" })
  end

  it "rejects a complete_checkout call whose payment_token looks like a raw PAN (§9)" do
    checkout = dispatcher.call(capability: "dev.ucp.shopping.checkout", action: "create_checkout",
                               arguments: { line_items: [], idempotency_key: "chk1" })[:structuredContent]

    expect do
      dispatcher.call(capability: "dev.ucp.shopping.checkout", action: "complete_checkout",
                      arguments: { checkout_id: checkout["id"], payment_token: "4111111111111111",
                                   idempotency_key: "chk1-complete" })
    end.to raise_error(Portage::Ucp::RawPanRejectedError)
  end

  it "reserves a pending transaction record before dispatch and settles it complete after (Phase 0)" do
    checkout = dispatcher.call(capability: "dev.ucp.shopping.checkout", action: "create_checkout",
                               arguments: { line_items: [{ product_id: "prod_1", quantity: 1 }],
                                            idempotency_key: "chk-tx" })[:structuredContent]

    dispatcher.call(capability: "dev.ucp.shopping.checkout", action: "complete_checkout",
                    arguments: { checkout_id: checkout["id"], payment_token: "tok_visa",
                                 idempotency_key: "chk-tx-complete" })

    record = transaction_log.find("chk-tx-complete")
    expect(record["status"]).to eq("complete")
    expect(record["checkout_id"]).to eq(checkout["id"])
    expect(record["payment_token_ref"]).not_to eq("tok_visa")
    expect(record["amount"]).to be_a(Integer)
    expect(record["currency"]).to eq(checkout["currency"])
    expect(record["completed_at"]).not_to be_nil
  end

  it "snapshots the settled order to the ledger, joinable to its transaction record (Phase 1)" do
    checkout = dispatcher.call(capability: "dev.ucp.shopping.checkout", action: "create_checkout",
                               arguments: { line_items: [{ product_id: "prod_1", quantity: 1 }],
                                            idempotency_key: "chk-ledger" })[:structuredContent]

    order = dispatcher.call(capability: "dev.ucp.shopping.checkout", action: "complete_checkout",
                            arguments: { checkout_id: checkout["id"], payment_token: "tok_visa",
                                         idempotency_key: "chk-ledger-complete" })[:structuredContent]["order"]

    tx_record = transaction_log.find("chk-ledger-complete")
    expect(tx_record["status"]).to eq("complete")

    snapshot = order_ledger.find(order["id"])
    expect(snapshot["idempotency_key"]).to eq("chk-ledger-complete")
    expect(snapshot["order"]).to eq(order)
  end

  it "writes nothing to the ledger and does not raise when the settled result has no order (Phase 1)" do
    dispatcher.call(capability: "dev.ucp.shopping.cart", action: "create_cart",
                    arguments: { line_items: [{ product_id: "prod_1", quantity: 1 }], idempotency_key: "cart-k1" })

    expect(File.exist?(@orders_path)).to be false
  end

  it "settles the transaction record complete before a ledger write failure surfaces (Phase 1)" do
    checkout = dispatcher.call(capability: "dev.ucp.shopping.checkout", action: "create_checkout",
                               arguments: { line_items: [{ product_id: "prod_1", quantity: 1 }],
                                            idempotency_key: "chk-ledger-fail" })[:structuredContent]

    allow(order_ledger).to receive(:record) do
      # By the time the ledger write is attempted, the transaction record
      # must already be durably `complete` — proves the ordering, not just
      # that it's documented.
      expect(transaction_log.find("chk-ledger-fail-complete")["status"]).to eq("complete")
      raise IOError, "disk full"
    end

    expect do
      dispatcher.call(capability: "dev.ucp.shopping.checkout", action: "complete_checkout",
                      arguments: { checkout_id: checkout["id"], payment_token: "tok_visa",
                                   idempotency_key: "chk-ledger-fail-complete" })
    end.to raise_error(IOError)

    expect(transaction_log.find("chk-ledger-fail-complete")["status"]).to eq("complete")
  end

  it "settles the transaction record failed, not left pending, when the adapter raises (Phase 0)" do
    expect do
      dispatcher.call(capability: "dev.ucp.shopping.checkout", action: "complete_checkout",
                      arguments: { checkout_id: "chk-missing", payment_token: "tok_visa",
                                   idempotency_key: "chk-tx-missing-complete" })
    end.to raise_error(KeyError)

    expect(transaction_log.find("chk-tx-missing-complete")["status"]).to eq("failed")
  end

  it "records a passing policy_decision on the transaction record before dispatch (Phase 2)" do
    checkout = dispatcher.call(capability: "dev.ucp.shopping.checkout", action: "create_checkout",
                               arguments: { line_items: [{ product_id: "prod_1", quantity: 1 }],
                                            idempotency_key: "chk-policy-pass" })[:structuredContent]

    dispatcher.call(capability: "dev.ucp.shopping.checkout", action: "complete_checkout",
                    arguments: { checkout_id: checkout["id"], payment_token: "tok_visa",
                                 idempotency_key: "chk-policy-pass-complete" })

    record = transaction_log.find("chk-policy-pass-complete")
    expect(record["policy_decision"]).to eq({ "allowed" => true })
    expect(record["status"]).to eq("complete")
  end

  it "blocks complete_checkout and settles the record failed when the merchant isn't allowlisted (Phase 2)" do
    policy.set("merchant_allowlist", ["some-other-shop.com"])
    checkout = dispatcher.call(capability: "dev.ucp.shopping.checkout", action: "create_checkout",
                               arguments: { line_items: [{ product_id: "prod_1", quantity: 1 }],
                                            idempotency_key: "chk-policy-block" })[:structuredContent]

    expect do
      dispatcher.call(capability: "dev.ucp.shopping.checkout", action: "complete_checkout",
                      arguments: { checkout_id: checkout["id"], payment_token: "tok_visa",
                                   idempotency_key: "chk-policy-block-complete" })
    end.to raise_error(Portage::Ucp::PolicyViolationError)

    record = transaction_log.find("chk-policy-block-complete")
    expect(record["status"]).to eq("failed")
    expect(record["policy_decision"]).to include("allowed" => false, "reason" => "merchant_not_allowlisted")
  end

  it "records a passing confirmation_outcome on the transaction record before dispatch (Phase 3)" do
    checkout = dispatcher.call(capability: "dev.ucp.shopping.checkout", action: "create_checkout",
                               arguments: { line_items: [{ product_id: "prod_1", quantity: 1 }],
                                            idempotency_key: "chk-confirm-pass" })[:structuredContent]

    dispatcher.call(capability: "dev.ucp.shopping.checkout", action: "complete_checkout",
                    arguments: { checkout_id: checkout["id"], payment_token: "tok_visa",
                                 idempotency_key: "chk-confirm-pass-complete" })

    record = transaction_log.find("chk-confirm-pass-complete")
    expect(record["confirmation_outcome"]).to eq({ "approved" => true })
    expect(record["status"]).to eq("complete")
  end

  it "denies dispatch and settles the record failed when the confirmer denies (Phase 3)" do
    denying_confirmer = instance_double(Portage::Ucp::Confirmer::AutoApprove)
    allow(denying_confirmer).to receive(:confirm!).and_raise(
      Portage::Ucp::ConfirmationDeniedError.new(
        "nope", reason: :denied, decision: { approved: false, reason: :denied }
      )
    )
    dispatcher = described_class.new(adapter: adapter, transaction_log: transaction_log, policy: policy,
                                     confirmer: denying_confirmer, shop: "shop.example.com")
    checkout = dispatcher.call(capability: "dev.ucp.shopping.checkout", action: "create_checkout",
                               arguments: { line_items: [{ product_id: "prod_1", quantity: 1 }],
                                            idempotency_key: "chk-confirm-deny" })[:structuredContent]

    expect do
      dispatcher.call(capability: "dev.ucp.shopping.checkout", action: "complete_checkout",
                      arguments: { checkout_id: checkout["id"], payment_token: "tok_visa",
                                   idempotency_key: "chk-confirm-deny-complete" })
    end.to raise_error(Portage::Ucp::ConfirmationDeniedError)

    record = transaction_log.find("chk-confirm-deny-complete")
    expect(record["status"]).to eq("failed")
    expect(record["confirmation_outcome"]).to include("approved" => false, "reason" => "denied")
  end

  it "routes cancel_order/request_return/refund_order through as dev.ucp.shopping.order actions (§16)" do
    checkout = dispatcher.call(capability: "dev.ucp.shopping.checkout", action: "create_checkout",
                               arguments: { line_items: [{ product_id: "prod_1", quantity: 2 }],
                                            idempotency_key: "chk-oc" })[:structuredContent]
    confirmation = dispatcher.call(capability: "dev.ucp.shopping.checkout", action: "complete_checkout",
                                   arguments: { checkout_id: checkout["id"], payment_token: "tok_visa",
                                                idempotency_key: "chk-oc-complete" })[:structuredContent]["order"]
    order_id = confirmation["id"]
    line_item_id = dispatcher.call(capability: "dev.ucp.shopping.order", action: "get_order",
                                   arguments: { order_id: order_id })[:structuredContent]["line_items"][0]["id"]

    refunded = dispatcher.call(capability: "dev.ucp.shopping.order", action: "refund_order",
                               arguments: { order_id: order_id,
                                            line_items: [{ id: line_item_id, quantity: 1 }],
                                            idempotency_key: "ref1" })[:structuredContent]
    expect(refunded["adjustments"].size).to eq(1)
    expect(refunded["adjustments"][0]["type"]).to eq("refund")

    returned = dispatcher.call(capability: "dev.ucp.shopping.order", action: "request_return",
                               arguments: { order_id: order_id,
                                            line_items: [{ id: line_item_id, quantity: 1 }],
                                            idempotency_key: "ret1", reason: "wrong size" })[:structuredContent]
    expect(returned["adjustments"].map { |a| a["type"] }).to eq(%w[refund return])
    expect(returned["adjustments"][1]["status"]).to eq("pending")

    canceled = dispatcher.call(capability: "dev.ucp.shopping.order", action: "cancel_order",
                               arguments: { order_id: order_id, idempotency_key: "can1" })[:structuredContent]
    expect(canceled["adjustments"].last["type"]).to eq("cancellation")
  end

  it "raises UnknownCapabilityError for a capability name that isn't registered" do
    expect { dispatcher.call(capability: "dev.ucp.shopping.nonexistent", action: "whatever", arguments: {}) }
      .to raise_error(Portage::Ucp::UnknownCapabilityError, /dev\.ucp\.shopping\.nonexistent/)
  end

  it "raises UnknownActionError for an action not defined on the capability" do
    expect { dispatcher.call(capability: "dev.ucp.shopping.catalog", action: "not_a_real_action", arguments: {}) }
      .to raise_error(Portage::Ucp::UnknownActionError, /not_a_real_action/)
  end

  it "raises CapabilityNotAdvertisedError when the adapter hasn't overridden any backing method" do
    bare_adapter = Portage::Ucp::Adapter.new
    dispatcher = described_class.new(adapter: bare_adapter)

    expect do
      dispatcher.call(capability: "dev.ucp.shopping.identity", action: "link_identity", arguments: { oauth_token: "t" })
    end
      .to raise_error(Portage::Ucp::CapabilityNotAdvertisedError, /dev\.ucp\.shopping\.identity/)
  end
end
