require "spec_helper"

RSpec.describe Portage::Ucp::Decision::EscalationPolicy do
  it "delegates the rule to Portage::Ucp::Support::Escalation" do
    allow(Portage::Ucp::Support::Escalation).to receive(:reason).and_call_original

    described_class.call(checkout_status: "ready_for_complete", signals: { warnings: ["dropped"] })

    expect(Portage::Ucp::Support::Escalation).to have_received(:reason)
      .with(checkout_status: "ready_for_complete", warnings: ["dropped"])
  end

  it "escalates on requires_escalation" do
    verdict = described_class.call(checkout_status: "requires_escalation")

    expect(verdict.escalate).to be(true)
    expect(verdict.reason).to eq(:requires_escalation)
  end

  it "does not escalate on other statuses with no signals" do
    verdict = described_class.call(checkout_status: "ready_for_complete")

    expect(verdict.escalate).to be(false)
    expect(verdict.reason).to be_nil
  end

  it "escalates on an explicit mismatch signal even without requires_escalation" do
    verdict = described_class.call(checkout_status: "ready_for_complete", signals: { mismatch: true })

    expect(verdict.escalate).to be(true)
    expect(verdict.reason).to eq(:mismatch)
  end

  it "escalates when warnings are present" do
    verdict = described_class.call(checkout_status: "ready_for_complete",
                                   signals: { warnings: ["Store dropped the requested item."] })

    expect(verdict.escalate).to be(true)
    expect(verdict.reason).to eq(:mismatch)
  end

  it "does not escalate on an empty warnings array" do
    verdict = described_class.call(checkout_status: "ready_for_complete", signals: { warnings: [] })

    expect(verdict.escalate).to be(false)
  end

  it "requires_escalation still wins over absent signals" do
    verdict = described_class.call(checkout_status: "requires_escalation", signals: { mismatch: false })

    expect(verdict.reason).to eq(:requires_escalation)
  end
end
