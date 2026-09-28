require "spec_helper"
require "stringio"

RSpec.describe Portage::Cli::SetupWizard do
  def run(answers)
    output = StringIO.new
    result = described_class.new(input: StringIO.new(answers), output: output).call
    [result, output.string]
  end

  it "lists the eight steps in the plan's own order (Phase 7 added RetailerKeys)" do
    expect(described_class::STEPS).to eq([
                                           Portage::Cli::SetupWizard::Steps::Shipping, Portage::Cli::SetupWizard::Steps::SearchKeys,
                                           Portage::Cli::SetupWizard::Steps::RetailerKeys, Portage::Cli::SetupWizard::Steps::AgentProfile,
                                           Portage::Cli::SetupWizard::Steps::BrowserImport,
                                           Portage::Cli::SetupWizard::Steps::IndexBuild, Portage::Cli::SetupWizard::Steps::Policy,
                                           Portage::Cli::SetupWizard::Steps::Handoff
                                         ])
  end

  it "skips every step on 'n' and touches nothing — always returns 0" do
    result, output = run("n\n" * described_class::STEPS.length)

    expect(result).to eq(0)
    described_class::STEPS.each { |step_class| expect(output).to include("== #{step_class.new(prompt: nil).title} ==") }
    expect(output.scan("Skipped.").length).to eq(described_class::STEPS.length)
  end

  it "re-runs cleanly on EOF (no input left) — every remaining step is treated as declined, not an error" do
    result, = run("")

    expect(result).to eq(0)
  end
end
