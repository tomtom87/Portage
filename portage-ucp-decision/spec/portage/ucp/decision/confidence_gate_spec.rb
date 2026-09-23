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
    it "asks the backend one question and gates on its confidence" do
      backend = instance_double(Portage::Ucp::Decision::ModelBackends::Jev)
      answer = Portage::Ucp::Decision::ModelBackends::Answer.new(type: "noul", confidence: 0.95)
      allow(backend).to receive(:ask).with(state: "help!", questions: instance_of(Hash)).and_return(
        { "urgency" => answer }
      )

      verdict = described_class.via_backend(backend: backend, state: "help!", question: "urgency",
                                            instructions: "Does this express urgency?", threshold: 0.8)

      expect(verdict.proceed).to be(true)
      expect(verdict.confidence).to eq(0.95)
    end
  end
end
