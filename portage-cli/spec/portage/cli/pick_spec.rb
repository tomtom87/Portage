require "spec_helper"
require "tmpdir"

RSpec.describe Portage::Cli::Pick do
  around { |example| Dir.mktmpdir { |dir| @history = Portage::Cli::History.new(path: File.join(dir, "h.json")) and example.run } }

  let(:offers) do
    [{ offer_ref: "of_aaaaaa", store: "https://shop.example", checkout: true, product_id: "p1", title: "Cold Brew",
       amount: 2400, currency: "USD", url: "https://shop.example/products/cold" },
     { offer_ref: "of_bbbbbb", store: "https://other.example", checkout: false, product_id: "p2",
       title: "Cold Brew Can", amount: nil, currency: nil, url: nil }]
  end
  let(:search_id) { @history.record_search(query: "cold", offer_count: 2, message: "ok", offers: offers)["search_id"] }

  def pick(*answers, via: "tty", comparer: nil, **opts)
    prompt = Portage::Cli::HumanPrompt.new(via: via, terminal: FakeTerminal.new(*answers))
    described_class.new(prompt: prompt, history: @history, comparer: comparer, **opts).call
  end

  it "builds each choice from a saved offer, url included" do
    search_id

    choices = pick(via: "agent")[:choices]

    expect(choices.first).to eq(ref: "of_aaaaaa", label: "https://shop.example — Cold Brew — 24.00 USD",
                                store: "https://shop.example", product_id: "p1", title: "Cold Brew", amount: 2400,
                                currency: "USD", checkout: true, url: "https://shop.example/products/cold")
    expect(choices[1][:label]).to eq("https://other.example — Cold Brew Can — price n/a — browse only")
    expect(choices.last).to include(ref: "compare", url: nil, relay: include("--compare REF"))
  end

  it "picks from the named search, not just the latest" do
    first = search_id
    @history.record_search(query: "tea", offer_count: 1, message: "ok",
                           offers: [offers.first.merge(offer_ref: "of_cccccc")])

    expect(pick("1", search: first)).to include(outcome: "picked", offer_ref: "of_aaaaaa", search_id: first)
    expect(pick("1")).to include(offer_ref: "of_cccccc")
  end

  it "reports picked with store, product and by: person for a tty answer" do
    search_id

    expect(pick("2")).to include(outcome: "picked", offer_ref: "of_bbbbbb", store: "https://other.example",
                                 product_id: "p2", by: "person")
  end

  it "validates a relayed --choose against the search" do
    search_id

    expect(pick(via: "agent", choose: "of_aaaaaa")).to include(outcome: "picked", by: "agent_relayed")
    expect(pick(via: "agent", choose: "compare")[:outcome]).to eq("offer_not_found")
  end

  it "says so when `v N` has no product page, and asks again" do
    search_id
    terminal = FakeTerminal.new("v 2", "v 3", "")
    prompt = Portage::Cli::HumanPrompt.new(via: "tty", terminal: terminal)

    result = described_class.new(prompt: prompt, history: @history).call

    expect(result[:outcome]).to eq("cancelled")
    expect(terminal.written).to include("No product page on record", "Nothing to view for that choice.")
  end

  it "keeps showing the same offers when compare finds nothing" do
    search_id
    comparer = ->(_offer) { { query: "Cold Brew", offers: [], message: "No comparable offers found." } }

    result = pick("3", "1", "1", comparer: comparer)

    expect(result).to include(outcome: "picked", offer_ref: "of_aaaaaa", search_id: search_id)
  end

  it "cancels when the compare question is left blank" do
    search_id

    expect(pick("3", "")[:outcome]).to eq("cancelled")
  end

  it "reports no_terminal when --via tty can't open one" do
    search_id
    allow(Portage::Cli::HumanPrompt).to receive(:open_terminal).and_raise(Errno::ENXIO)
    prompt = Portage::Cli::HumanPrompt.new(via: "tty")

    expect(described_class.new(prompt: prompt, history: @history).call[:outcome]).to eq("no_terminal")
  end

  it "reports an unknown --view ref as offer_not_found" do
    expect(pick(via: "agent", view: "of_nope")[:outcome]).to eq("offer_not_found")
  end
end
