require "spec_helper"

RSpec.describe Portage::Cli::ApprovalPolicy do
  def policy(data) = Portage::Ucp::Policy.new(path: File.join(Dir.tmpdir, "unused.json"), data: data)

  it "defaults to any, and fails closed to person on a value it doesn't know" do
    expect(described_class.level(policy({}))).to eq("any")
    expect(described_class.level(policy("require_approval" => "off"))).to eq("off")
    expect(described_class.level(policy("require_approval" => "sometimes"))).to eq("person")
  end

  it "orders the levels off < any < person" do
    expect(described_class.lowering?("person", "any")).to be true
    expect(described_class.lowering?("any", "off")).to be true
    expect(described_class.lowering?("any", "person")).to be false
    expect(described_class.lowering?("any", "any")).to be false
  end

  it "counts approvals per level" do
    person = { "approved_by" => "person" }
    relayed = { "approved_by" => "agent_relayed" }
    none = { "approved" => false }

    expect([person, relayed, none, nil].map { |q| described_class.satisfied?(q, "off") }).to all(be true)
    expect([person, relayed, none].map { |q| described_class.satisfied?(q, "any") }).to eq([true, true, false])
    expect([person, relayed, none].map { |q| described_class.satisfied?(q, "person") }).to eq([true, false, false])
  end
end
