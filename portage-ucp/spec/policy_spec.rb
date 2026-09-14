require "spec_helper"
require "tmpdir"

RSpec.describe Portage::Ucp::Policy do
  around { |example| Dir.mktmpdir { |dir| @path = File.join(dir, "nested", "policy.json") and example.run } }

  def policy = described_class.load(path: @path)

  it "defaults every check to unconfigured (permissive) when no file exists" do
    p = policy
    expect(p.per_transaction_cap).to be_nil
    expect(p.rolling_cap).to be_nil
    expect(p.velocity).to be_nil
    expect(p.merchant_allowlist).to eq([])
    expect(p.token_scope("anyref")).to be_nil
  end

  it "persists a top-level field across a fresh instance pointed at the same path" do
    policy.set("per_transaction_cap", { "amount" => 5000, "currency" => "USD" })

    fresh = described_class.load(path: @path)
    expect(fresh.per_transaction_cap).to eq({ "amount" => 5000, "currency" => "USD" })
  end

  it "sets and reads back a per-token scope, keyed by token_ref" do
    policy.set_token_scope("ref1", { "merchants" => ["shop.example.com"], "max_amount" => 1000 })

    fresh = described_class.load(path: @path)
    expect(fresh.token_scope("ref1")).to eq({ "merchants" => ["shop.example.com"], "max_amount" => 1000 })
    expect(fresh.token_scope("ref2")).to be_nil
  end

  it "chmods the file 0600 on write" do
    policy.set("merchant_allowlist", ["shop.example.com"])

    expect(File.stat(@path).mode & 0o777).to eq(0o600)
  end
end
