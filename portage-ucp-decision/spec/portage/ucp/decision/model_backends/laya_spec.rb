require "spec_helper"
require "securerandom"
require "tmpdir"

RSpec.describe Portage::Ucp::Decision::ModelBackends::Laya do
  let(:question) do
    Portage::Ucp::Decision::ModelBackends::Question.new(type: "noul", instructions: "Does this express urgency?")
  end

  it "raises BackendNotConfiguredError with no bridge script or custom command configured" do
    backend = described_class.new(bridge_script: nil, command: nil)

    expect { backend.ask(state: "help!", questions: { "urgency" => question }) }
      .to raise_error(Portage::Ucp::Decision::BackendNotConfiguredError, /LAYA_BRIDGE_SCRIPT/)
  end

  it "raises BackendNotConfiguredError when the bridge script path doesn't exist" do
    backend = described_class.new(bridge_script: "/no/such/laya_bridge.py", command: nil)

    expect { backend.ask(state: "help!", questions: { "urgency" => question }) }
      .to raise_error(Portage::Ucp::Decision::BackendNotConfiguredError, %r{/no/such/laya_bridge.py})
  end

  it "raises BackendNotConfiguredError when python isn't on PATH" do
    Dir.mktmpdir do |dir|
      script = File.join(dir, "laya_bridge.py")
      File.write(script, "")
      backend = described_class.new(bridge_script: script,
                                    python: "definitely-not-a-real-python-#{SecureRandom.hex(4)}", command: nil)

      expect { backend.ask(state: "help!", questions: { "urgency" => question }) }
        .to raise_error(Portage::Ucp::Decision::BackendNotConfiguredError, /LAYA_PYTHON/)
    end
  end

  it "invokes python against the bridge script and returns typed answers with confidence" do
    Dir.mktmpdir do |dir|
      script = File.join(dir, "laya_bridge.py")
      File.write(script, "")
      allow(Open3).to receive(:capture3).with("python3", script, stdin_data: instance_of(String)).and_return(
        [{ answers: { "urgency" => { type: "noul", confidence: 0.6, noul: 0.0 } } }.to_json, "",
         instance_double(Process::Status, success?: true)]
      )
      backend = described_class.new(bridge_script: script, python: "python3", command: nil)

      answers = backend.ask(state: "help!", questions: { "urgency" => question })

      expect(answers["urgency"].confidence).to eq(0.6)
    end
  end

  it "raises BackendError when the bridge script exits non-zero" do
    Dir.mktmpdir do |dir|
      script = File.join(dir, "laya_bridge.py")
      File.write(script, "")
      allow(Open3).to receive(:capture3).and_return(["", "traceback...",
                                                     instance_double(Process::Status, success?: false)])
      backend = described_class.new(bridge_script: script, python: "python3", command: nil)

      expect { backend.ask(state: "help!", questions: { "urgency" => question }) }
        .to raise_error(Portage::Ucp::Decision::BackendError, /traceback/)
    end
  end

  it "raises BackendError with the offending output when the bridge script emits invalid JSON" do
    Dir.mktmpdir do |dir|
      script = File.join(dir, "laya_bridge.py")
      File.write(script, "")
      allow(Open3).to receive(:capture3).and_return(["not json", "", instance_double(Process::Status, success?: true)])
      backend = described_class.new(bridge_script: script, python: "python3", command: nil)

      expect { backend.ask(state: "help!", questions: { "urgency" => question }) }
        .to raise_error(Portage::Ucp::Decision::BackendError, /invalid JSON/)
    end
  end

  it "prefers a fully custom command over bridge_script/python when both are given" do
    allow(Open3).to receive(:capture3).with("some-wrapper", stdin_data: instance_of(String)).and_return(
      [{ answers: { "urgency" => { type: "noul", confidence: 0.4 } } }.to_json, "",
       instance_double(Process::Status, success?: true)]
    )
    backend = described_class.new(bridge_script: "/no/such/laya_bridge.py", command: "some-wrapper")

    answers = backend.ask(state: "help!", questions: { "urgency" => question })

    expect(answers["urgency"].confidence).to eq(0.4)
  end
end
