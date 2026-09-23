require "spec_helper"

RSpec.describe Portage::Ucp::Decision::ConfidenceGate do
  it "proceeds when confidence meets the threshold" do
    verdict = described_class.call(confidence: 0.9, threshold: 0.8)

    expect(verdict.proceed).to be(true)
  end

  it "does not proceed when confidence is below the threshold" do
    verdict = described_class.call(confidence: 0.5, threshold: 0.8)

    expect(verdict.proceed).to be(false)
  end

  it "proceeds when confidence exactly equals the threshold" do
    verdict = described_class.call(confidence: 0.8, threshold: 0.8)

    expect(verdict.proceed).to be(true)
  end

  describe ".via_backend" do
    let(:backend) { instance_double(Portage::Ucp::Decision::ModelBackends::Jev) }

    def answering(answer)
      allow(backend).to receive(:ask).with(state: "checkout", questions: instance_of(Hash))
                                     .and_return({ "q" => answer })
    end

    def gate(**)
      described_class.via_backend(backend: backend, state: "checkout", question: "q",
                                  instructions: "Safe to complete unattended?", threshold: 0.8, **)
    end

    def answer(**) = Portage::Ucp::Decision::ModelBackends::Answer.new(**)

    # Jev's real noul answer: a yes-probability and no `confidence` field.
    it "gates a noul on its yes-probability" do
      answering(answer(type: "noul", confidence: nil, value: 0.95))

      expect(gate).to have_attributes(proceed: true, confidence: 0.95)
    end

    it "doesn't proceed on a low noul yes-probability" do
      answering(answer(type: "noul", confidence: nil, value: 0.37))

      expect(gate.proceed).to be(false)
    end

    it "proceeds on a choice only when the chosen option matches proceed_on: at or above the threshold" do
      answering(answer(type: "choice", confidence: 0.9, value: "proceed"))

      expect(gate(type: "choice", criteria: { "proceed" => nil, "escalate" => nil }, proceed_on: "proceed").proceed)
        .to be(true)
    end

    it "doesn't proceed on a confident choice of the wrong option" do
      answering(answer(type: "choice", confidence: 0.95, value: "escalate"))

      verdict = gate(type: "choice", criteria: { "proceed" => nil, "escalate" => nil }, proceed_on: "proceed")

      expect(verdict).to have_attributes(proceed: false, confidence: 0.95)
    end

    it "matches a score against a Range proceed_on:" do
      answering(answer(type: "score", confidence: 0.83, value: 0.11))

      expect(gate(type: "score", criteria: %w[low medium high], proceed_on: 0..0.5).proceed).to be(true)
    end

    it "requires proceed_on: for a choice or score, before asking the backend" do
      allow(backend).to receive(:ask)

      expect { gate(type: "choice", criteria: { "a" => nil }) }.to raise_error(ArgumentError, /proceed_on:/)
      expect(backend).not_to have_received(:ask)
    end

    it "raises BackendError when the answer carries nothing to gate on" do
      answering(answer(type: "choice", confidence: nil, value: "proceed"))

      expect { gate(type: "choice", criteria: { "proceed" => nil }, proceed_on: "proceed") }
        .to raise_error(Portage::Ucp::Decision::BackendError, /no confidence/)
    end
  end
end
