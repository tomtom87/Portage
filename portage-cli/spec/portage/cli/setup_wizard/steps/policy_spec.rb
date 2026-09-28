require "spec_helper"
require "stringio"

RSpec.describe Portage::Cli::SetupWizard::Steps::Policy do
  def run(answers)
    output = StringIO.new
    prompt = Portage::Cli::SetupWizard::Prompt.new(input: StringIO.new(answers), output: output)
    described_class.new(prompt: prompt).call
    output.string
  end

  it "makes no policy call when every question is left blank" do
    expect(Portage::Cli).not_to receive(:run_policy_set)

    output = run("\n\n")
    expect(output).to include("No policy changes made.")
  end

  it "converts a major-units cap to minor units and delegates to Cli.run_policy_set" do
    expect(Portage::Cli).to receive(:run_policy_set).with(%w[--per-transaction-cap 20000 --currency USD])

    run("200\nUSD\n\n")
  end

  it "reports 'not set' and makes no cap call when a cap is given with no currency" do
    expect(Portage::Cli).not_to receive(:run_policy_set)

    output = run("200\n\n\n")
    expect(output).to include("No currency given")
  end

  it "rejects a non-numeric cap instead of silently treating it as 0" do
    expect(Portage::Cli).not_to receive(:run_policy_set)

    output = run("abc\n\n")
    expect(output).to include("Not a number — cap not set.")
  end

  it "rejects a cap like '12x' that Float() would otherwise coerce via #to_f" do
    expect(Portage::Cli).not_to receive(:run_policy_set)

    output = run("12x\n\n")
    expect(output).to include("Not a number — cap not set.")
  end

  it "rejects a zero or negative cap" do
    expect(Portage::Cli).not_to receive(:run_policy_set)

    output = run("0\n\n")
    expect(output).to include("Not a number — cap not set.")
  end

  it "splits a comma-separated allowlist into one --allow per host" do
    expect(Portage::Cli).to receive(:run_policy_set).with(%w[--allow shop-a.example.com --allow shop-b.example.com])

    run("\nshop-a.example.com, shop-b.example.com\n")
  end

  it "combines a cap and an allowlist into one call" do
    expect(Portage::Cli).to receive(:run_policy_set)
      .with(%w[--per-transaction-cap 5000 --currency GBP --allow shop.example.com])

    run("50\nGBP\nshop.example.com\n")
  end
end
