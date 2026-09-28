require "spec_helper"
require "stringio"

RSpec.describe Portage::Cli::SetupWizard::Steps::Handoff do
  around { |example| Dir.mktmpdir { |dir| @config_path = File.join(dir, "config.json") and example.run } }

  def config = Portage::Cli::Config.load(path: @config_path)

  def run(answers)
    output = StringIO.new
    with_env("PORTAGE_AUTO_OPEN_CHECKOUT" => nil) do
      allow(Portage::Cli::Config).to receive(:load).and_return(config)
      prompt = Portage::Cli::SetupWizard::Prompt.new(input: StringIO.new(answers), output: output)
      described_class.new(prompt: prompt).call
    end
    output.string
  end

  it "leaves auto-open off (the default) and unsaved when the answer matches the current default" do
    output = run("\n")

    expect(config.get("auto_open_checkout")).to be_nil
    expect(output).to include("Left unchanged.")
  end

  it "turns auto-open on when confirmed" do
    run("y\n")

    expect(config.get("auto_open_checkout")).to be(true)
  end

  it "explains the Phase 5 seam — the hand-off-only host list isn't built yet" do
    output = run("n\n")

    expect(output).to include("hand-off-only host list").and include("not built yet")
  end
end
