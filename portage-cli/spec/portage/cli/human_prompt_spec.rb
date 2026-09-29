require "spec_helper"

RSpec.describe Portage::Cli::HumanPrompt do
  let(:choices) { [{ label: "shop.example — Cold Brew" }, { label: "other.example — Cold Brew Can" }] }

  def prompt(*answers, **opts)
    terminal = FakeTerminal.new(*answers)
    [described_class.new(terminal: terminal, **opts), terminal]
  end

  describe "#surface" do
    it "is tty under auto when there's a terminal and the run isn't --json" do
      expect(prompt.first.surface).to eq("tty")
    end

    it "is agent under auto for --json, even with a terminal" do
      expect(prompt(json: true).first.surface).to eq("agent")
    end

    it "is agent under auto when /dev/tty can't be opened" do
      allow(described_class).to receive(:open_terminal).and_raise(Errno::ENXIO)

      expect(described_class.new.surface).to eq("agent")
    end

    it "takes an explicit tty or agent as given" do
      expect(prompt(via: "agent").first.surface).to eq("agent")
      expect(prompt(via: "tty", json: true).first.surface).to eq("tty")
    end

    it "rejects an unknown via" do
      expect { described_class.new(via: "dialog") }.to raise_error(ArgumentError, /--via/)
    end
  end

  describe "#choose" do
    it "lists the choices and returns the picked index" do
      human, terminal = prompt("2")

      expect(human.choose("Pick an offer", choices)).to eq(1)
      expect(terminal.written).to include("1. shop.example — Cold Brew", "2. other.example — Cold Brew Can")
    end

    it "returns nil on a blank answer or end of input" do
      expect(prompt("").first.choose("Pick", choices)).to be_nil
      expect(prompt.first.choose("Pick", choices)).to be_nil
    end

    it "asks again after an answer that isn't a listed number" do
      human, terminal = prompt("0", "cheapest", "1")

      expect(human.choose("Pick", choices)).to eq(0)
      expect(terminal.written.scan("Not one of the choices.").length).to eq(2)
    end

    it "views on `v N`, then asks again — viewing is never the answer" do
      viewed = []
      human, terminal = prompt("v 2", "V1", "1")

      index = human.choose("Pick", choices, view: ->(choice) { viewed << choice[:label] and "Opened." })

      expect(index).to eq(0)
      expect(viewed).to eq(["other.example — Cold Brew Can", "shop.example — Cold Brew"])
      expect(terminal.written).to include("v N to view", "Opened.")
    end
  end

  describe "#confirm" do
    it "is yes only for y or yes" do
      expect(%w[y YES].map { |a| prompt(a).first.confirm("Buy?") }).to eq([true, true])
      expect(["n", "", "sure"].map { |a| prompt(a).first.confirm("Buy?") }).to eq([false, false, false])
    end

    it "views on `v` and asks again" do
      human, terminal = prompt("v", "y")

      expect(human.confirm("Buy?", view: -> { "Opened the page." })).to be true
      expect(terminal.written).to include("[y/N, v to view]", "Opened the page.")
    end
  end

  it "raises NoTerminal when asked on tty with no controlling terminal" do
    allow(described_class).to receive(:open_terminal).and_raise(Errno::ENXIO)
    human = described_class.new(via: "tty")

    expect { human.confirm("Buy?") }.to raise_error(described_class::NoTerminal, %r{/dev/tty})
  end
end
