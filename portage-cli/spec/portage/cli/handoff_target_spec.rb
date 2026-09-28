require "spec_helper"

RSpec.describe Portage::Cli::HandoffTarget do
  around { |example| Dir.mktmpdir { |dir| @config_path = File.join(dir, "config.json") and example.run } }

  def config(data = {})
    path = @config_path
    File.write(path, JSON.generate(data)) unless data.empty?
    Portage::Cli::Config.load(path: path)
  end

  it "defaults to \"default\" when nothing is set at any level" do
    with_env("PORTAGE_HANDOFF_TARGET" => nil) do
      target = described_class.new(config: config)

      expect(target.kind).to eq("default")
      expect(target).to be_default
      expect(target.label).to eq("default")
    end
  end

  it "reads print/profile/agent:<name> from the override" do
    expect(described_class.new(override: "print", config: config)).to be_print
    expect(described_class.new(override: "profile", config: config)).to be_profile

    agent = described_class.new(override: "agent:openclaw", config: config)
    expect(agent).to be_agent
    expect(agent.agent_name).to eq("openclaw")
    expect(agent.label).to eq("agent:openclaw")
  end

  it "raises ArgumentError on an unknown target" do
    expect { described_class.new(override: "carrier-pigeon", config: config) }
      .to raise_error(ArgumentError, /Unknown --handoff-target "carrier-pigeon"/)
  end

  it "follows override > env > config precedence, same as Setting" do
    with_env("PORTAGE_HANDOFF_TARGET" => "print") do
      expect(described_class.new(config: config("handoff_target" => "profile")).kind).to eq("print")
      expect(described_class.new(override: "agent:x", config: config("handoff_target" => "profile")).label)
        .to eq("agent:x")
    end
  end

  it "falls through to config.json when no override or env is set" do
    target = described_class.new(config: config("handoff_target" => "profile"))

    expect(target).to be_profile
  end

  it "treats a blank override as unset, falling through to the default" do
    with_env("PORTAGE_HANDOFF_TARGET" => nil) do
      target = described_class.new(override: "  ", config: config)

      expect(target).to be_default
    end
  end
end
