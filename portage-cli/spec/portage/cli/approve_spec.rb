require "spec_helper"
require "tmpdir"

RSpec.describe Portage::Cli::Approve do
  around do |example|
    Dir.mktmpdir do |dir|
      @quotes = Portage::Cli::Quotes.new(dir: File.join(dir, "quotes"))
      @history = Portage::Cli::History.new(path: File.join(dir, "h.json"))
      example.run
    end
  end

  let(:quote) do
    @quotes.create(store: "https://shop.example", product_id: "p1", qty: 1, total: 1999, currency: "GBP",
                   title: "Brass Wall Light", url: "https://shop.example/products/wall-light")
  end

  def approve(*answers, via: "tty", **opts)
    prompt = Portage::Cli::HumanPrompt.new(via: via, terminal: FakeTerminal.new(*answers))
    described_class.new(quote_id: quote["quote_id"], prompt: prompt, quotes: @quotes, history: @history, **opts).call
  end

  it "summarises title, store, qty, total and url" do
    expect(described_class.summary(quote, history: @history)).to include(
      title: "Brass Wall Light", store: "https://shop.example", qty: 1, total: 1999, currency: "GBP",
      total_display: "19.99 GBP", url: "https://shop.example/products/wall-light", approved_by: nil
    )
  end

  it "says unknown for a quote with no total" do
    unpriced = @quotes.create(store: "https://shop.example", product_id: "p1", qty: 1, total: nil, currency: nil)

    expect(described_class.summary(unpriced, history: @history)[:total_display]).to eq("unknown")
  end

  it "approves on a tty yes, recording the person" do
    expect(approve("yes")).to include(outcome: "approved", approved_by: "person")
    expect(@quotes.find(quote["quote_id"])).to include("approved" => true, "approved_by" => "person")
  end

  it "cancels on anything but yes" do
    expect(approve("")[:outcome]).to eq("cancelled")
    expect(@quotes.find(quote["quote_id"])).to include("approved" => false)
  end

  it "asks nobody on the agent surface" do
    result = approve(via: "agent")

    expect(result).to include(outcome: "needs_approval", quote_id: quote["quote_id"])
    expect(result[:summary][:url]).to eq("https://shop.example/products/wall-light")
    expect(@quotes.find(quote["quote_id"])).to include("approved" => false)
  end

  it "records a relayed yes without asking, even on the tty surface" do
    expect(approve(relayed_yes: true)).to include(outcome: "approved", approved_by: "agent_relayed")
  end

  context "under require_approval person" do
    it "tells the agent to hand the question to the person's terminal" do
      result = approve(via: "agent", level: "person")

      expect(result[:outcome]).to eq("needs_approval")
      expect(result[:message]).to include("`portage approve #{quote['quote_id']}` in their own terminal")
      expect(result[:message]).not_to include("--relayed-yes")
    end

    it "doesn't record a relayed yes that could never count" do
      expect(approve(relayed_yes: true, level: "person")[:outcome]).to eq("needs_approval")
      expect(@quotes.find(quote["quote_id"])).to include("approved" => false)
    end

    it "still approves on a tty yes" do
      expect(approve("y", level: "person")).to include(outcome: "approved", approved_by: "person")
    end
  end

  it "--view never approves" do
    expect(approve("y", view: true)[:outcome]).to eq("viewed")
    expect(@quotes.find(quote["quote_id"])).to include("approved" => false)
  end

  it "reports no_terminal when --via tty can't open one" do
    allow(Portage::Cli::HumanPrompt).to receive(:open_terminal).and_raise(Errno::ENXIO)
    prompt = Portage::Cli::HumanPrompt.new(via: "tty")

    result = described_class.new(quote_id: quote["quote_id"], prompt: prompt, quotes: @quotes).call

    expect(result[:outcome]).to eq("no_terminal")
  end
end
