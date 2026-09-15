require "spec_helper"
require "tmpdir"

RSpec.describe Portage::Ucp::Support::TransactionLog do
  around { |example| Dir.mktmpdir { |dir| @path = File.join(dir, "nested", "transactions.json") and example.run } }

  def log = described_class.new(path: @path)

  it "reserves a pending record before anything settles" do
    record = log.reserve(idempotency_key: "k1", checkout_id: "chk_1", payment_token_ref: "ref1", shop: "shop1")

    expect(record).to include("status" => "pending", "checkout_id" => "chk_1", "payment_token_ref" => "ref1",
                              "shop" => "shop1", "policy_decision" => nil, "confirmation_outcome" => nil,
                              "completed_at" => nil)
    expect(log.find("k1")).to eq(record)
  end

  it "settles a reserved record complete, filling in amount/currency" do
    log.reserve(idempotency_key: "k1", checkout_id: "chk_1", payment_token_ref: "ref1")

    log.complete(idempotency_key: "k1", status: "complete", amount: 500, currency: "USD")

    record = log.find("k1")
    expect(record["status"]).to eq("complete")
    expect(record["amount"]).to eq(500)
    expect(record["currency"]).to eq("USD")
    expect(record["completed_at"]).not_to be_nil
  end

  it "settles a reserved record failed without amount/currency" do
    log.reserve(idempotency_key: "k1", checkout_id: "chk_1", payment_token_ref: "ref1")

    log.complete(idempotency_key: "k1", status: "failed")

    record = log.find("k1")
    expect(record["status"]).to eq("failed")
    expect(record["amount"]).to be_nil
  end

  it "raises rather than completing a key that was never reserved" do
    expect { log.complete(idempotency_key: "missing", status: "complete") }.to raise_error(KeyError)
  end

  it "raises on an unrecognized status" do
    log.reserve(idempotency_key: "k1", checkout_id: "chk_1", payment_token_ref: "ref1")

    expect { log.complete(idempotency_key: "k1", status: "bogus") }.to raise_error(ArgumentError)
  end

  it "chmods the file 0600 on write" do
    log.reserve(idempotency_key: "k1", checkout_id: "chk_1", payment_token_ref: "ref1")

    expect(File.stat(@path).mode & 0o777).to eq(0o600)
  end

  it "persists across a fresh instance pointed at the same path (simulating a new process)" do
    log.reserve(idempotency_key: "k1", checkout_id: "chk_1", payment_token_ref: "ref1")

    fresh = described_class.new(path: @path)
    expect(fresh.find("k1")["status"]).to eq("pending")

    fresh.complete(idempotency_key: "k1", status: "complete", amount: 100, currency: "USD")
    expect(log.find("k1")["status"]).to eq("complete")
  end

  it "keeps records for different idempotency_keys independent" do
    log.reserve(idempotency_key: "k1", checkout_id: "chk_1", payment_token_ref: "ref1")
    log.reserve(idempotency_key: "k2", checkout_id: "chk_2", payment_token_ref: "ref2")

    log.complete(idempotency_key: "k1", status: "complete")

    expect(log.find("k1")["status"]).to eq("complete")
    expect(log.find("k2")["status"]).to eq("pending")
  end

  it "records a policy_decision mid-flight without changing status (Phase 2)" do
    log.reserve(idempotency_key: "k1", checkout_id: "chk_1", payment_token_ref: "ref1")

    log.record_decision(idempotency_key: "k1", policy_decision: { "allowed" => true })

    record = log.find("k1")
    expect(record["status"]).to eq("pending")
    expect(record["policy_decision"]).to eq({ "allowed" => true })
  end

  it "carries policy_decision/confirmation_outcome through #complete" do
    log.reserve(idempotency_key: "k1", checkout_id: "chk_1", payment_token_ref: "ref1")

    log.complete(idempotency_key: "k1", status: "failed",
                 policy_decision: { "allowed" => false, "reason" => "spend_cap_exceeded" },
                 confirmation_outcome: "denied")

    record = log.find("k1")
    expect(record["policy_decision"]).to eq({ "allowed" => false, "reason" => "spend_cap_exceeded" })
    expect(record["confirmation_outcome"]).to eq("denied")
  end

  it "returns only completed records for the given shop within the window (#completed_since)" do
    log.reserve(idempotency_key: "k1", checkout_id: "chk_1", payment_token_ref: "ref1", shop: "shop-a")
    log.complete(idempotency_key: "k1", status: "complete", amount: 100, currency: "USD")

    log.reserve(idempotency_key: "k2", checkout_id: "chk_2", payment_token_ref: "ref2", shop: "shop-a")
    # left pending — must not count

    log.reserve(idempotency_key: "k3", checkout_id: "chk_3", payment_token_ref: "ref3", shop: "shop-b")
    log.complete(idempotency_key: "k3", status: "complete", amount: 200, currency: "USD")

    results = log.completed_since(Time.now - 3600, shop: "shop-a")
    expect(results.map { |r| r["idempotency_key"] }).to eq(["k1"])
  end

  it "excludes completed records outside the window (#completed_since)" do
    stale_clock = -> { Time.now - 7200 }
    stale_log = described_class.new(path: @path, clock: stale_clock)
    stale_log.reserve(idempotency_key: "k1", checkout_id: "chk_1", payment_token_ref: "ref1", shop: "shop-a")
    stale_log.complete(idempotency_key: "k1", status: "complete", amount: 100, currency: "USD")

    expect(log.completed_since(Time.now - 3600, shop: "shop-a")).to eq([])
  end

  describe "pluggable store (§33)" do
    let(:memory_store) do
      Class.new(Portage::Ucp::Support::TransactionLog::Store) do
        def initialize
          @records = {}
        end

        def reserve(record) = @records[record["idempotency_key"]] = record

        def complete(idempotency_key, updates)
          record = @records[idempotency_key]
          record&.merge!(updates)
        end

        def record_decision(idempotency_key, policy_decision)
          record = @records[idempotency_key]
          record&.merge!("policy_decision" => policy_decision)
        end

        def record_confirmation(idempotency_key, confirmation_outcome)
          record = @records[idempotency_key]
          record&.merge!("confirmation_outcome" => confirmation_outcome)
        end

        def find(idempotency_key) = @records[idempotency_key]

        def completed_since(_since, shop:)
          @records.values.select { |r| r["status"] == "complete" && r["shop"] == shop }
        end
      end.new
    end

    it "routes reserve/complete/find through an injected store without touching a file" do
      log = described_class.new(store: memory_store)

      log.reserve(idempotency_key: "k1", checkout_id: "chk_1", payment_token_ref: "ref1", shop: "shop1")
      log.complete(idempotency_key: "k1", status: "complete", amount: 100, currency: "USD")

      expect(log.find("k1")).to include("status" => "complete", "amount" => 100)
      expect(File.exist?(@path)).to be(false)
    end

    it "still raises KeyError from TransactionLog, not the store, for an unreserved key" do
      log = described_class.new(store: memory_store)

      expect { log.complete(idempotency_key: "nope", status: "complete") }.to raise_error(KeyError)
    end

    it "raises NotImplementedError from the abstract Store" do
      expect { Portage::Ucp::Support::TransactionLog::Store.new.reserve({}) }
        .to raise_error(Portage::Ucp::NotImplementedError)
    end
  end
end
