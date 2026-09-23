require "spec_helper"
require "tmpdir"

RSpec.describe Portage::Cli::History do
  around do |example|
    Dir.mktmpdir { |dir| @path = File.join(dir, "nested", "history.json") and example.run }
  end

  def history(now: Time.now) = described_class.new(path: @path, now: now)

  it "returns nothing for a fresh history" do
    expect(history.purchases).to eq([])
    expect(history.searches).to eq([])
  end

  it "round-trips a purchase through the file" do
    history.record_purchase(url: "https://shop.example", query: "cold", outcome: "purchased", source: "native_ucp",
                            checkout_id: "chk_1", checkout_status: "completed", total: 1200, currency: "USD",
                            items: [{ "id" => "v1", "title" => "Cold Brew", "quantity" => 2 }], message: "Purchased.")

    entry = history.purchases.first
    expect(entry).to include("url" => "https://shop.example", "query" => "cold", "outcome" => "purchased",
                             "checkout_id" => "chk_1", "checkout_status" => "completed", "total" => 1200,
                             "items" => [{ "id" => "v1", "title" => "Cold Brew", "quantity" => 2 }])
  end

  it "round-trips a search through the file" do
    history.record_search(query: "cold", offer_count: 3, message: "Found 3 offer(s).")

    expect(history.searches.first).to include("query" => "cold", "offer_count" => 3)
    expect(history.searches.first).not_to have_key("url")
  end

  it "records the store on a search made by a buy that never reached checkout" do
    history.record_search(query: "cold", url: "https://shop.example", offer_count: 0, message: "No match.")

    expect(history.searches.first).to include("url" => "https://shop.example")
  end

  it "keeps only the most recent MAX_ENTRIES purchases" do
    h = history
    (described_class::MAX_ENTRIES + 5).times do |i|
      h.record_purchase(url: "https://shop.example", query: "q#{i}", outcome: "purchased",
                        message: "ok")
    end

    expect(h.purchases.length).to eq(described_class::MAX_ENTRIES)
    expect(h.purchases.first["query"]).to eq("q5")
  end

  it "honors a limit passed to purchases/searches" do
    h = history
    3.times { |i| h.record_search(query: "q#{i}", offer_count: 0, message: "none") }

    expect(h.searches(limit: 2).map { |e| e["query"] }).to eq(%w[q1 q2])
  end

  it "clears only the requested kind" do
    h = history
    h.record_purchase(url: "https://shop.example", query: "cold", outcome: "purchased",
                      message: "ok")
    h.record_search(query: "cold", offer_count: 1, message: "ok")

    h.clear(kind: "purchases")

    expect(h.purchases).to eq([])
    expect(h.searches.length).to eq(1)
  end

  it "clears both kinds when no kind is given" do
    h = history
    h.record_purchase(url: "https://shop.example", query: "cold", outcome: "purchased",
                      message: "ok")
    h.record_search(query: "cold", offer_count: 1, message: "ok")

    h.clear

    expect(h.purchases).to eq([])
    expect(h.searches).to eq([])
  end

  it "treats a corrupt history file as an empty one" do
    FileUtils.mkdir_p(File.dirname(@path))
    File.write(@path, "{not json")

    expect(history.purchases).to eq([])
  end

  it "keeps working when the history can't be written" do
    allow(File).to receive(:write).and_raise(Errno::EACCES)

    expect(history.record_search(query: "cold", offer_count: 1, message: "ok")).to include("query" => "cold")
  end
end
