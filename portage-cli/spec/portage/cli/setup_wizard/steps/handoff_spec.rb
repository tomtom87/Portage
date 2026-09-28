require "spec_helper"
require "stringio"

RSpec.describe Portage::Cli::SetupWizard::Steps::Handoff do
  around { |example| Dir.mktmpdir { |dir| @config_path = File.join(dir, "config.json") and example.run } }

  def config = Portage::Cli::Config.load(path: @config_path)

  def run(answers)
    output = StringIO.new
    with_env("PORTAGE_AUTO_OPEN_CHECKOUT" => nil, "PORTAGE_HANDOFF_TARGET" => nil) do
      allow(Portage::Cli::Config).to receive(:load).and_return(config)
      prompt = Portage::Cli::SetupWizard::Prompt.new(input: StringIO.new(answers), output: output)
      described_class.new(prompt: prompt).call
    end
    output.string
  end

  it "leaves auto-open off (the default) and unsaved when the answer matches the current default" do
    output = run("\n\n\n\n")

    expect(config.get("auto_open_checkout")).to be_nil
    expect(output).to include("Left unchanged.")
  end

  it "turns auto-open on when confirmed" do
    run("y\n\n\n\n")

    expect(config.get("auto_open_checkout")).to be(true)
  end

  it "states the disclaimer up front" do
    output = run("\n\n\n\n")

    expect(output).to include("Portage is open-source software provided as-is, without warranty")
  end

  it "saves a valid hand-off target" do
    output = run("\nprint\n\n\n")

    expect(config.get("handoff_target")).to eq("print")
    expect(output).to include("Saved to ~/.portage/config.json.")
  end

  it "rejects an unknown hand-off target and saves nothing" do
    output = run("\nsomewhere-else\n\n\n")

    expect(config.get("handoff_target")).to be_nil
    expect(output).to include("Unknown --handoff-target").and include("Not saved.")
  end

  it "leaves the hand-off target unchanged on a blank answer" do
    run("\n\n\n\n")

    expect(config.get("handoff_target")).to be_nil
  end

  it "approves a named agent with a command, never a webhook" do
    output = run("\n\nopenclaw\nopenclaw handoff --json\n\n")

    agent = config.get("handoff_agents")["openclaw"]
    expect(agent).to eq("command" => %w[openclaw handoff --json], "approved" => true)
    expect(output).to include("Approved \"openclaw\"")
  end

  it "approves a named agent with a webhook when no command is given" do
    output = run("\n\nstorefront\n\nhttps://example.com/hooks/handoff\n\n")

    agent = config.get("handoff_agents")["storefront"]
    expect(agent).to eq("webhook" => "https://example.com/hooks/handoff", "approved" => true)
    expect(output).to include("Approved \"storefront\"")
  end

  it "saves no agent at all when neither a command nor a webhook is given" do
    run("\n\nstorefront\n\n\n\n")

    expect(config.get("handoff_agents")).to be_nil
  end

  it "shows the current hand-off-only host list, seeded with Amazon" do
    output = run("\n\n\n\n")

    expect(output).to include("Current hand-off-only hosts").and include("amazon.com")
  end

  it "replaces the hand-off-only host list when given one" do
    output = run("\n\n\nexample.com, another.example\n")

    expect(config.get("handoff_only_hosts")).to eq(%w[example.com another.example])
    expect(output).to include("Saved 2 host(s)")
  end

  it "leaves the hand-off-only host list unchanged on a blank answer" do
    run("\n\n\n\n")

    expect(config.get("handoff_only_hosts")).to be_nil
  end
end
