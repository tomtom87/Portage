require "spec_helper"
require "tmpdir"

RSpec.describe Portage::Ucp::PolicyGuard do
  around { |example| Dir.mktmpdir { |dir| @dir = dir and example.run } }

  let(:policy) { Portage::Ucp::Policy.new(path: File.join(@dir, "policy.json")) }
  let(:transaction_log) { Portage::Ucp::Support::TransactionLog.new(path: File.join(@dir, "transactions.json")) }

  def check!(**overrides)
    described_class.check!(amount: 1000, currency: "USD", merchant: "shop.example.com", token_ref: "ref1",
                           policy: policy, transaction_log: transaction_log, **overrides)
  end

  it "allows a call against an unconfigured policy" do
    expect(check!).to eq({ allowed: true })
  end

  describe "spend cap" do
    it "allows an amount at or under the per-transaction cap" do
      policy.set("per_transaction_cap", { "amount" => 1000, "currency" => "USD" })

      expect { check! }.not_to raise_error
    end

    it "blocks an amount over the per-transaction cap" do
      policy.set("per_transaction_cap", { "amount" => 999, "currency" => "USD" })

      expect { check! }.to raise_error(Portage::Ucp::PolicyViolationError) { |e|
        expect(e.reason).to eq(:per_transaction_cap_exceeded)
      }
    end

    it "rejects a currency mismatch against the cap rather than converting" do
      policy.set("per_transaction_cap", { "amount" => 999_999, "currency" => "EUR" })

      expect { check! }.to raise_error(Portage::Ucp::PolicyViolationError) { |e|
        expect(e.reason).to eq(:currency_mismatch)
      }
    end

    it "blocks when prior completed spend plus this amount exceeds the rolling cap" do
      policy.set("rolling_cap", { "amount" => 1500, "currency" => "USD", "window_seconds" => 3600 })
      transaction_log.reserve(idempotency_key: "prior", checkout_id: "chk_prior", payment_token_ref: "refX",
                              shop: "shop.example.com")
      transaction_log.complete(idempotency_key: "prior", status: "complete", amount: 600, currency: "USD")

      expect { check! }.to raise_error(Portage::Ucp::PolicyViolationError) { |e|
        expect(e.reason).to eq(:rolling_spend_cap_exceeded)
      }
    end

    it "does not count a pending or failed prior transaction toward the rolling cap" do
      policy.set("rolling_cap", { "amount" => 1500, "currency" => "USD", "window_seconds" => 3600 })
      transaction_log.reserve(idempotency_key: "prior", checkout_id: "chk_prior", payment_token_ref: "refX",
                              shop: "shop.example.com")
      transaction_log.complete(idempotency_key: "prior", status: "failed", amount: 5000, currency: "USD")

      expect { check! }.not_to raise_error
    end

    it "skips both cap checks when amount is nil" do
      policy.set("per_transaction_cap", { "amount" => 1, "currency" => "USD" })

      expect(check!(amount: nil)).to eq({ allowed: true })
    end
  end

  describe "velocity" do
    it "blocks when the completed-transaction count meets the limit" do
      policy.set("velocity", { "count" => 1, "window_seconds" => 3600 })
      transaction_log.reserve(idempotency_key: "prior", checkout_id: "chk_prior", payment_token_ref: "refX",
                              shop: "shop.example.com")
      transaction_log.complete(idempotency_key: "prior", status: "complete", amount: 1, currency: "USD")

      expect { check! }.to raise_error(Portage::Ucp::PolicyViolationError) { |e|
        expect(e.reason).to eq(:velocity_exceeded)
      }
    end

    it "allows when under the limit" do
      policy.set("velocity", { "count" => 5, "window_seconds" => 3600 })

      expect { check! }.not_to raise_error
    end
  end

  describe "merchant allowlist" do
    it "allows an exact host match" do
      policy.set("merchant_allowlist", ["shop.example.com"])

      expect { check! }.not_to raise_error
    end

    it "allows a subdomain of an allowlisted registrable domain" do
      policy.set("merchant_allowlist", ["example.com"])

      expect { check!(merchant: "checkout.example.com") }.not_to raise_error
    end

    it "does not allow a lookalike host via substring match" do
      policy.set("merchant_allowlist", ["shopify.com"])

      expect { check!(merchant: "evil-shopify.com") }.to raise_error(Portage::Ucp::PolicyViolationError) { |e|
        expect(e.reason).to eq(:merchant_not_allowlisted)
      }
    end

    it "blocks a merchant not on a configured allowlist" do
      policy.set("merchant_allowlist", ["other-shop.com"])

      expect { check! }.to raise_error(Portage::Ucp::PolicyViolationError) { |e|
        expect(e.reason).to eq(:merchant_not_allowlisted)
      }
    end
  end

  describe "per-token scope" do
    it "blocks a merchant outside the token's scoped merchants" do
      policy.set_token_scope("ref1", { "merchants" => ["other-shop.com"] })

      expect { check! }.to raise_error(Portage::Ucp::PolicyViolationError) { |e|
        expect(e.reason).to eq(:token_scope_merchant)
      }
    end

    it "blocks an amount over the token's scoped max_amount" do
      policy.set_token_scope("ref1", { "max_amount" => 500, "currency" => "USD" })

      expect { check! }.to raise_error(Portage::Ucp::PolicyViolationError) { |e|
        expect(e.reason).to eq(:token_scope_amount)
      }
    end

    it "allows a token with no scope configured" do
      expect { check!(token_ref: "unscoped") }.not_to raise_error
    end
  end

  it "returns a passing decision without raising" do
    expect(check!).to eq({ allowed: true })
  end
end
