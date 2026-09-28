require "spec_helper"
require "stringio"

RSpec.describe Portage::Cli::SetupWizard::Steps::IndexBuild do
  def run(answers)
    output = StringIO.new
    prompt = Portage::Cli::SetupWizard::Prompt.new(input: StringIO.new(answers), output: output)
    described_class.new(prompt: prompt).call
    output.string
  end

  it "does nothing when the final 'run it now?' confirm is declined" do
    expect(Portage::Cli).not_to receive(:run_index_build)

    run("n\n")
  end

  # Delegates to Cli.run_index_build — the real command — rather than
  # re-implementing any of Phase 2b/2c.
  it "delegates to Cli.run_index_build with no sources/queries override when confirmed" do
    expect(Portage::Cli).to receive(:run_index_build).with([], refresh: false)

    run("y\n")
  end
end
