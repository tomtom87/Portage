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

  # A real subprocess, not a stubbed Open3: the "bridge" is a Ruby script run
  # by this Ruby, passed as an absolute LAYA_PYTHON the way a venv's python
  # would be.
  def bridge(dir, body)
    File.join(dir, "laya_bridge.rb").tap { |script| File.write(script, body) }
  end

  def backend_for(script, **opts)
    described_class.new(bridge_script: script, python: RbConfig.ruby, command: nil, **opts)
  end

  it "runs the bridge script with the request on stdin and returns typed answers" do
    Dir.mktmpdir do |dir|
      script = bridge(dir, <<~RUBY)
        require "json"
        request = JSON.parse($stdin.read)
        answer = { type: "noul", confidence: 0.6, noul: request["state"] == "help!" ? 0.9 : 0.0 }
        puts({ answers: { "urgency" => answer } }.to_json)
      RUBY

      answers = backend_for(script).ask(state: "help!", questions: { "urgency" => question })

      expect(answers["urgency"]).to have_attributes(confidence: 0.6, value: 0.9)
    end
  end

  it "raises BackendError with stderr when the bridge script exits non-zero" do
    Dir.mktmpdir do |dir|
      script = bridge(dir, 'warn "traceback..."; exit 1')

      expect { backend_for(script).ask(state: "help!", questions: { "urgency" => question }) }
        .to raise_error(Portage::Ucp::Decision::BackendError, /traceback/)
    end
  end

  it "raises BackendError with the offending output when the bridge script emits invalid JSON" do
    Dir.mktmpdir do |dir|
      script = bridge(dir, 'puts "not json"')

      expect { backend_for(script).ask(state: "help!", questions: { "urgency" => question }) }
        .to raise_error(Portage::Ucp::Decision::BackendError, /unreadable answer.*not json/)
    end
  end

  it "raises BackendError when the reply has no answers" do
    Dir.mktmpdir do |dir|
      script = bridge(dir, 'puts "{}"')

      expect { backend_for(script).ask(state: "help!", questions: { "urgency" => question }) }
        .to raise_error(Portage::Ucp::Decision::BackendError, /KeyError/)
    end
  end

  it "kills the bridge and raises BackendError when it overruns its timeout" do
    Dir.mktmpdir do |dir|
      script = bridge(dir, "sleep 5")

      expect { backend_for(script, timeout: 0.2).ask(state: "help!", questions: { "urgency" => question }) }
        .to raise_error(Portage::Ucp::Decision::BackendError, /timed out after 0.2s/)
    end
  end

  it "raises BackendError, not Errno::ENOENT, when a custom command can't start" do
    backend = described_class.new(command: "definitely-not-a-real-bridge-#{SecureRandom.hex(4)}")

    expect { backend.ask(state: "help!", questions: { "urgency" => question }) }
      .to raise_error(Portage::Ucp::Decision::BackendError, /couldn't run/)
  end

  it "prefers a fully custom command over bridge_script/python when both are given" do
    Dir.mktmpdir do |dir|
      script = bridge(dir, 'puts({ answers: { "urgency" => { type: "noul", confidence: 0.4 } } }.to_json)')
      backend = described_class.new(bridge_script: "/no/such/laya_bridge.py",
                                    command: [RbConfig.ruby, "-rjson", script])

      answers = backend.ask(state: "help!", questions: { "urgency" => question })

      expect(answers["urgency"].confidence).to eq(0.4)
    end
  end
end
