require "spec_helper"
require "stringio"

RSpec.describe Portage::Cli::SetupWizard::Prompt do
  def prompt(answer) = described_class.new(input: StringIO.new(answer), output: (@output = StringIO.new))

  describe "#confirm" do
    it "returns the default on a blank answer (Enter)" do
      expect(prompt("\n").confirm("Continue?", default: true)).to be(true)
      expect(prompt("\n").confirm("Continue?", default: false)).to be(false)
    end

    it "returns true only for an answer starting with 'y' (any case)" do
      expect(prompt("y\n").confirm("Continue?", default: false)).to be(true)
      expect(prompt("Yes\n").confirm("Continue?", default: false)).to be(true)
      expect(prompt("n\n").confirm("Continue?", default: true)).to be(false)
    end

    it "shows which answer Enter picks" do
      prompt("\n").confirm("Continue?", default: true)
      expect(@output.string).to include("[Y/n]")

      prompt("\n").confirm("Continue?", default: false)
      expect(@output.string).to include("[y/N]")
    end
  end

  describe "#ask" do
    it "returns the typed answer, trimmed" do
      expect(prompt("  1 Main St  \n").ask("Street")).to eq("1 Main St")
    end

    it "returns nil for a blank answer or EOF — Enter/no input means 'keep the current value'" do
      expect(prompt("\n").ask("Street")).to be_nil
      expect(prompt("").ask("Street")).to be_nil
    end

    it "shows the hint alongside the question" do
      prompt("\n").ask("Street", hint: "already set")
      expect(@output.string).to include("Street (already set):")
    end
  end

  describe "#ask_secret" do
    it "returns the typed answer without an IO#noecho terminal available (falls back to a plain read)" do
      # StringIO has no #noecho — this proves the fallback path both reads
      # the answer correctly and never raises.
      expect(prompt("s3cr3t\n").ask_secret("API key")).to eq("s3cr3t")
    end

    it "returns nil for a blank answer" do
      expect(prompt("\n").ask_secret("API key")).to be_nil
    end

    it "never prints the secret's own value" do
      prompt("s3cr3t\n").ask_secret("API key")
      expect(@output.string).not_to include("s3cr3t")
    end
  end

  describe "#say" do
    it "writes a line to output" do
      out = StringIO.new
      described_class.new(output: out).say("hello")

      expect(out.string).to eq("hello\n")
    end
  end
end
