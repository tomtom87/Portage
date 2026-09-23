require "spec_helper"

RSpec.describe Portage::Ucp::Decision::EscalationPolicy do
  it "escalates on requires_escalation" do
    verdict = described_class.call(checkout_status: "requires_escalation")

    expect(verdict.escalate).to be(true)
    expect(verdict.reason).to eq(:requires_escalation)
  end

  it "does not escalate on other statuses" do
    verdict = described_class.call(checkout_status: "ready_for_complete")

    expect(verdict.escalate).to be(false)
    expect(verdict.reason).to be_nil
  end

  it "ignores signals for now" do
    verdict = described_class.call(checkout_status: "ready_for_complete", signals: { mismatch: true })

    expect(verdict.escalate).to be(false)
  end
end
