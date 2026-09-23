require "spec_helper"
require "securerandom"

RSpec.describe Portage::Ucp::Decision::ModelBackends::Laya do
  let(:question) do
    Portage::Ucp::Decision::ModelBackends::Question.new(type: "noul", instructions: "Does this express urgency?")
  end

  it "raises BackendNotConfiguredError when the command isn't on PATH" do
    backend = described_class.new(command: "definitely-not-a-real-command-#{SecureRandom.hex(4)}")

    expect { backend.ask(state: "help!", questions: { "urgency" => question }) }
      .to raise_error(Portage::Ucp::Decision::BackendNotConfiguredError)
  end

  it "shells out and returns typed answers with confidence" do
    allow(Open3).to receive(:capture3).and_return(
      [{ answers: { "urgency" => { type: "noul", confidence: 0.6, noul: 0.0 } } }.to_json, "",
       instance_double(Process::Status, success?: true)]
    )
    backend = described_class.new(command: "echo")

    answers = backend.ask(state: "help!", questions: { "urgency" => question })

    expect(answers["urgency"].confidence).to eq(0.6)
  end

  it "raises BackendError when the command exits non-zero" do
    allow(Open3).to receive(:capture3).and_return(["", "traceback...",
                                                   instance_double(Process::Status, success?: false)])
    backend = described_class.new(command: "echo")

    expect { backend.ask(state: "help!", questions: { "urgency" => question }) }
      .to raise_error(Portage::Ucp::Decision::BackendError, /traceback/)
  end
end
