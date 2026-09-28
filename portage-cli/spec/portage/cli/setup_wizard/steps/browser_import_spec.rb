require "spec_helper"
require "stringio"

RSpec.describe Portage::Cli::SetupWizard::Steps::BrowserImport do
  def run(answers)
    output = StringIO.new
    prompt = Portage::Cli::SetupWizard::Prompt.new(input: StringIO.new(answers), output: output)
    described_class.new(prompt: prompt).call
    output.string
  end

  # Delegates to Cli.run_browser_import (the real command, with its own
  # confirmation gate intact) rather than re-implementing any of Phase 3 —
  # this only asserts the delegation and the flag it passes through.
  it "delegates to Cli.run_browser_import with no --browser flag when Enter (autodetect) is given" do
    expect(Portage::Cli).to receive(:run_browser_import).with([])

    run("\n")
  end

  it "passes --browser through when one is named" do
    expect(Portage::Cli).to receive(:run_browser_import).with(["--browser", "firefox"])

    run("firefox\n")
  end
end
