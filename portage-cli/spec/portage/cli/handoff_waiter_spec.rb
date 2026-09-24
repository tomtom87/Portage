require "spec_helper"

RSpec.describe Portage::Cli::HandoffWaiter do
  let(:transaction_log) { Portage::Ucp::Support::TransactionLog.new }
  let(:reconciler) { instance_double(Portage::Cli::HandoffReconciler) }
  let(:sleeps) { [] }
  let(:sleeper) { ->(seconds) { sleeps << seconds } }

  def waiter(clock: -> { Time.now }, wait_timeout_override: nil)
    described_class.new(reconciler: reconciler, transaction_log: transaction_log,
                        wait_timeout_override: wait_timeout_override, clock: clock, sleeper: sleeper)
  end

  def reserve_pending(checkout_id: "chk_1", expires_at: nil)
    transaction_log.reserve(idempotency_key: "k1", checkout_id: checkout_id, payment_token_ref: nil,
                            shop: "shop.example", settled_by: "shopper", expires_at: expires_at)
    transaction_log.find("k1")
  end

  it "returns immediately once the first poll settles, without sleeping" do
    record = reserve_pending
    result = Portage::Cli::HandoffReconciler::Result.new(idempotency_key: "k1", settled: true, status: "complete")
    allow(reconciler).to receive(:call).and_return(result)

    settled_events = []
    outcome = waiter.call(record) { |event, res| settled_events << [event, res] }

    expect(outcome).to eq(result)
    expect(sleeps).to be_empty
    expect(settled_events).to eq([[:settled, result]])
  end

  it "polls with backoff until it settles" do
    record = reserve_pending
    pending = Portage::Cli::HandoffReconciler::Result.new(idempotency_key: "k1", settled: false, status: "pending")
    settled = Portage::Cli::HandoffReconciler::Result.new(idempotency_key: "k1", settled: true, status: "failed")
    allow(reconciler).to receive(:call).and_return(pending, pending, settled)

    outcome = waiter.call(record)

    expect(outcome).to eq(settled)
    expect(sleeps.length).to eq(2)
    expect(sleeps[1]).to be > sleeps[0]
  end

  it "emits :status only when the store-reported status changes" do
    record = reserve_pending
    incomplete = Portage::Cli::HandoffReconciler::Result.new(idempotency_key: "k1", settled: false,
                                                             status: "pending", checkout_status: "incomplete")
    ready = Portage::Cli::HandoffReconciler::Result.new(idempotency_key: "k1", settled: false, status: "pending",
                                                        checkout_status: "ready_for_complete")
    settled = Portage::Cli::HandoffReconciler::Result.new(idempotency_key: "k1", settled: true, status: "complete")
    allow(reconciler).to receive(:call).and_return(incomplete, incomplete, ready, settled)

    events = []
    waiter.call(record) { |event, res| events << [event, res.checkout_status || res.status] }

    expect(events).to eq([[:status, "incomplete"], [:status, "ready_for_complete"], [:settled, "complete"]])
  end

  it "gives up at the deadline without settling, and never emits :settled" do
    record = reserve_pending
    pending = Portage::Cli::HandoffReconciler::Result.new(idempotency_key: "k1", settled: false, status: "pending")
    allow(reconciler).to receive(:call).and_return(pending)
    now = Time.now
    times = [now, now, now + 3600].each
    clock = -> { times.next }

    events = []
    outcome = waiter(clock: clock, wait_timeout_override: "30m").call(record) { |event, _res| events << event }

    expect(outcome.settled).to be false
    expect(events).not_to include(:settled)
  end

  it "stops at the checkout's own expires_at when the timeout is off" do
    record = reserve_pending(expires_at: (Time.now + 10).utc.iso8601)
    pending = Portage::Cli::HandoffReconciler::Result.new(idempotency_key: "k1", settled: false, status: "pending")
    allow(reconciler).to receive(:call).and_return(pending)
    now = Time.now
    times = [now, now + 20].each
    clock = -> { times.next }

    outcome = waiter(clock: clock, wait_timeout_override: "off").call(record)

    expect(outcome.settled).to be false
    expect(sleeps).to be_empty
  end

  it "leaves the record pending on Ctrl-C, never settling from the wait itself" do
    record = reserve_pending
    pending = Portage::Cli::HandoffReconciler::Result.new(idempotency_key: "k1", settled: false, status: "pending")
    allow(reconciler).to receive(:call).and_return(pending)
    interrupting_sleeper = ->(_seconds) { raise Interrupt }

    outcome = described_class.new(reconciler: reconciler, transaction_log: transaction_log,
                                  sleeper: interrupting_sleeper).call(record)

    expect(outcome.settled).to be false
    expect(transaction_log.find("k1")["status"]).to eq("pending")
  end

  it "re-fetches the record from the log on every poll" do
    reserve_pending
    seen = []
    allow(reconciler).to receive(:call) do |record|
      seen << record["idempotency_key"]
      Portage::Cli::HandoffReconciler::Result.new(idempotency_key: record["idempotency_key"], settled: true,
                                                  status: "complete")
    end

    waiter.call(transaction_log.find("k1"))

    expect(seen).to eq(["k1"])
  end
end
