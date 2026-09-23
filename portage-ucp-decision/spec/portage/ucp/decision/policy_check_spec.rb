require "spec_helper"

RSpec.describe Portage::Ucp::Decision::PolicyCheck do
  let(:transaction_log) { double("transaction_log", completed_since: []) }

  it "delegates the rule to Portage::Ucp::PolicyGuard" do
    policy = Portage::Ucp::Policy.new(data: {})
    allow(Portage::Ucp::PolicyGuard).to receive(:check!).and_call_original

    described_class.call(amount: 500, currency: "USD", merchant: "shop.test", token_ref: "ref", policy: policy,
                         transaction_log: transaction_log)

    expect(Portage::Ucp::PolicyGuard).to have_received(:check!)
      .with(amount: 500, currency: "USD", merchant: "shop.test", token_ref: "ref", policy: policy,
            transaction_log: transaction_log)
  end

  it "returns an allowed verdict when PolicyGuard passes" do
    policy = Portage::Ucp::Policy.new(data: {})

    verdict = described_class.call(amount: 500, currency: "USD", merchant: "https://shop.test", token_ref: nil,
                                   policy: policy, transaction_log: transaction_log)

    expect(verdict.allowed).to be(true)
    expect(verdict.reason).to be_nil
  end

  it "returns a denied verdict with the PolicyGuard reason when it fails" do
    policy = Portage::Ucp::Policy.new(data: { "merchant_allowlist" => ["other.test"] })

    verdict = described_class.call(amount: 500, currency: "USD", merchant: "https://shop.test", token_ref: nil,
                                   policy: policy, transaction_log: transaction_log)

    expect(verdict.allowed).to be(false)
    expect(verdict.reason).to eq(:merchant_not_allowlisted)
  end
end
