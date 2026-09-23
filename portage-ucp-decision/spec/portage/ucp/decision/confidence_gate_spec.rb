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

    def gate
      described_class.via_backend(backend: backend, state: "checkout", question: "q",
                                  instructions: "Safe to complete unattended?", threshold: 0.8)
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

    it "asks the backend a noul question" do
      answering(answer(type: "noul", confidence: nil, value: 0.9))
      gate

      expect(backend).to have_received(:ask) do |questions:, **|
        expect(questions.fetch("q")).to have_attributes(type: "noul", instructions: "Safe to complete unattended?")
      end
    end

    # A confident answer of the wrong kind must never clear the threshold:
    # a choice's `confidence` is certainty, not a yes-probability.
    it "raises BackendError when the answer carries no yes-probability to gate on" do
      answering(answer(type: "choice", confidence: 0.99, value: "escalate"))

      expect { gate }.to raise_error(Portage::Ucp::Decision::BackendError, /no probability/)
    end

    it "raises BackendError, not KeyError, when the backend leaves the question unanswered" do
      allow(backend).to receive(:ask).and_return({})

      expect { gate }.to raise_error(Portage::Ucp::Decision::BackendError, /no answer for "q"/)
    end
  end
end
