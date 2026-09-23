require "spec_helper"

RSpec.describe Portage::Ucp::Support::Escalation do
  it "escalates requires_escalation" do
    expect(described_class.reason(checkout_status: "requires_escalation")).to eq(:requires_escalation)
  end

  it "escalates a mismatch on any warning" do
    expect(described_class.reason(checkout_status: "ready_for_complete", warnings: ["dropped"])).to eq(:mismatch)
  end

  it "lets the store's requires_escalation win over a mismatch" do
    expect(described_class.reason(checkout_status: "requires_escalation", warnings: ["dropped"]))
      .to eq(:requires_escalation)
  end

  it "keeps going with no warnings, empty or absent" do
    expect(described_class.reason(checkout_status: "ready_for_complete")).to be_nil
    expect(described_class.reason(checkout_status: "ready_for_complete", warnings: [])).to be_nil
    expect(described_class.reason(checkout_status: "ready_for_complete", warnings: nil)).to be_nil
  end
end
