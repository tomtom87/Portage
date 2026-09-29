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

  describe "saved offers" do
    def offer(ref, **fields)
      { offer_ref: ref, store: "https://shop.example", product_id: "p1", title: "Cold Brew", amount: 2400,
        currency: "USD", url: "https://shop.example/products/cold", checkout: true }.merge(fields)
    end

    it "keeps a search's offers, with when they were found, and resolves an offer_ref to one of them" do
      history(now: Time.at(1_700_000_000))
        .record_search(query: "cold", offer_count: 1, message: "ok", offers: [offer("of_aaaaaa")])

      expect(history.offer("of_aaaaaa")).to eq(
        "offer_ref" => "of_aaaaaa", "store" => "https://shop.example", "product_id" => "p1",
        "title" => "Cold Brew", "amount" => 2400, "currency" => "USD",
        "url" => "https://shop.example/products/cold", "checkout" => true, "found_at" => 1_700_000_000,
        "query" => "cold"
      )
    end

    it "keeps an already-saved, string-keyed offer's found_at when it's saved again" do
      saved = offer("of_aaaaaa").transform_keys(&:to_s).merge("found_at" => 1_600_000_000)
      history(now: Time.at(1_700_000_000)).record_search(query: "compare", offer_count: 1, message: "ok",
                                                         offers: [saved])

      expect(history.offer("of_aaaaaa")).to include("store" => "https://shop.example", "found_at" => 1_600_000_000)
    end

    it "leaves the offers key off a search that found none" do
      history.record_search(query: "cold", offer_count: 0, message: "none")

      expect(history.searches.first).not_to have_key("offers")
    end

    it "finds an offer in an older search, and returns nil for an unknown ref" do
      h = history
      h.record_search(query: "cold", offer_count: 1, message: "ok", offers: [offer("of_aaaaaa")])
      h.record_search(query: "tea", offer_count: 1, message: "ok", offers: [offer("of_bbbbbb", product_id: "p2")])

      expect(h.offer("of_aaaaaa")).to include("product_id" => "p1", "query" => "cold")
      expect(h.offer("of_nope")).to be_nil
    end

    it "gives a search that kept offers a search_id, and none to one that didn't" do
      h = history
      kept = h.record_search(query: "cold", offer_count: 1, message: "ok", offers: [offer("of_aaaaaa")])
      empty = h.record_search(query: "tea", offer_count: 0, message: "none")

      expect(kept["search_id"]).to match(/\Ase_[0-9a-f]{8}\z/)
      expect(empty).not_to have_key("search_id")
    end

    it "finds the latest search with offers for LAST (or nil), and any one by its search_id" do
      h = history
      first = h.record_search(query: "cold", offer_count: 1, message: "ok", offers: [offer("of_aaaaaa")])
      second = h.record_search(query: "tea", offer_count: 1, message: "ok", offers: [offer("of_bbbbbb")])
      h.record_search(query: "none", offer_count: 0, message: "none")

      expect([h.search, h.search("LAST"), h.search("last")].map { |s| s["query"] }).to eq(%w[tea tea tea])
      expect(h.search(first["search_id"])["query"]).to eq("cold")
      expect(second["search_id"]).not_to eq(first["search_id"])
      expect(h.search("se_00000000")).to be_nil
    end

    it "buys an offer saved with its own query by that query, not the search's" do
      h = history
      h.record_search(query: "compare: https://shop.example (product p1)", offer_count: 1, message: "ok",
                      offers: [offer("of_aaaaaa", query: "Cold Brew")])

      expect(h.offer("of_aaaaaa")).to include("query" => "Cold Brew")
    end

    it "prefers the most recent search when a ref appears twice" do
      h = history
      h.record_search(query: "old", offer_count: 1, message: "ok", offers: [offer("of_aaaaaa", amount: 100)])
      h.record_search(query: "new", offer_count: 1, message: "ok", offers: [offer("of_aaaaaa", amount: 200)])

      expect(h.offer("of_aaaaaa")).to include("amount" => 200, "query" => "new")
    end
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
