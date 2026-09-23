require "spec_helper"

RSpec.describe Portage::Ucp::Decision::PolicyCheck do
  let(:transaction_log) { double("transaction_log", completed_since: []) }

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
