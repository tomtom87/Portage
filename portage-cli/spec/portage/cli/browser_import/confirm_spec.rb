require "spec_helper"
require "stringio"

RSpec.describe Portage::Cli::BrowserImport::Confirm do
  let(:plan) { { kept: [{ domain: "shop.example" }] } }
  let(:output) { StringIO.new }

  def confirm(interactive:, answer: "")
    described_class.new(interactive: interactive, input: StringIO.new(answer), output: output)
  end

  it "never saves on a dry run, even with --yes" do
    expect(confirm(interactive: true, answer: "y\n").call(plan, yes: true, dry_run: true)).to eq(:dry_run)
  end

  it "has nothing to ask about when no domain was kept" do
    expect(confirm(interactive: true).call({ kept: [] }, yes: true, dry_run: false)).to eq(:nothing)
  end

  it "saves on an explicit --yes without prompting" do
    expect(confirm(interactive: false).call(plan, yes: true, dry_run: false)).to eq(:save)
    expect(output.string).to be_empty
  end

  it "never saves (and never prompts) under --json or with no TTY unless --yes was given" do
    expect(confirm(interactive: false, answer: "y\n").call(plan, yes: false, dry_run: false))
      .to eq(:needs_confirmation)
    expect(output.string).to be_empty
  end

  it "asks at a TTY and saves only on 'y'" do
    expect(confirm(interactive: true, answer: "y\n").call(plan, yes: false, dry_run: false)).to eq(:save)
    expect(output.string).to include("Save these 1 store(s)")
    expect(confirm(interactive: true, answer: "\n").call(plan, yes: false, dry_run: false)).to eq(:declined)
    expect(confirm(interactive: true, answer: "").call(plan, yes: false, dry_run: false)).to eq(:declined)
  end
end
