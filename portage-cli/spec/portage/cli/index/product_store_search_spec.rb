require "spec_helper"
require "tmpdir"

# `portage index search` and `index show --products` paging
# (docs/plans/local-catalogue.md Phase 2).
RSpec.describe Portage::Cli::Index::ProductStore do
  around do |example|
    Dir.mktmpdir do |dir|
      @path = File.join(dir, "products.json")
      example.run
    end
  end

  let(:products) { described_class.new(path: @path) }

  def seed
    products.upsert("title:brass-wall-light", origin: "https://yard.example", seen_at: 1, title: "Brass Wall Light",
                                              brand: "Yard", category: "594")
    products.upsert("title:glass-pendant", origin: "https://other.example", seen_at: 1, title: "Glass Pendant",
                                           brand: "Brass & Co", category: "594")
    products.upsert("title:trail-boots", origin: "https://yard.example", seen_at: 1, title: "Trail Boots",
                                         brand: "Lems", category: "187")
    products.upsert("title:trail-boots", origin: "https://yard.example", seen_at: 2, title: "Hiking Boots")
  end

  def titles(results) = results.map { |e| e["title"] }

  describe "#search" do
    before { seed }

    it "matches on title, brand and aliases, ranking a title hit above a brand-only hit" do
      expect(titles(products.search("brass"))).to eq(["Brass Wall Light", "Glass Pendant"])
    end

    it "requires every query word, and matches a simple plural" do
      expect(titles(products.search("wall lights"))).to eq(["Brass Wall Light"])
      expect(titles(products.search("brass boots"))).to eq([])
    end

    it "finds a product by a title it went by before (an alias)" do
      expect(titles(products.search("trail"))).to eq(["Hiking Boots"])
    end

    it "filters by category id and by store host" do
      expect(titles(products.search("brass", category: "594", store: "other.example"))).to eq(["Glass Pendant"])
      expect(titles(products.search("brass", store: "https://yard.example/any/path"))).to eq(["Brass Wall Light"])
      expect(titles(products.search("boots", category: "594"))).to eq([])
    end

    it "matches a subdomain of the --store host" do
      products.upsert("title:brass-tap", origin: "https://www.taps.example", seen_at: 1, title: "Brass Tap")

      expect(titles(products.search("brass tap", store: "taps.example"))).to eq(["Brass Tap"])
      expect(titles(products.search("brass tap", store: "ps.example"))).to eq([])
    end

    it "caps results at limit" do
      expect(products.search("brass", limit: 1).length).to eq(1)
    end

    it "returns nothing for a query with no words, or FTS syntax, rather than raising" do
      expect(products.search("  ")).to eq([])
      expect(titles(products.search("brass\"(*:^"))).to eq(["Brass Wall Light", "Glass Pendant"])
    end

    it "says it is using FTS5" do
      expect(products.search_engine).to eq("fts5")
    end
  end

  it "returns nothing, without creating the database, when there is no index" do
    expect(products.search("brass")).to eq([])
    expect(File.exist?(Portage::Cli::Index::Database.path_for(@path))).to be(false)
  end

  describe "without FTS5 (a system SQLite built without it)" do
    before do
      allow(Portage::Cli::Index::Schema).to receive(:fts5_available?).and_return(false)
      seed
    end

    it "falls back to a LIKE match with the same filters" do
      expect(products.search_engine).to eq("like")
      expect(titles(products.search("brass")).sort).to eq(["Brass Wall Light", "Glass Pendant"])
      expect(titles(products.search("brass", store: "yard.example"))).to eq(["Brass Wall Light"])
      expect(titles(products.search("trail"))).to eq(["Hiking Boots"])
    end
  end

  describe "#page and #count" do
    before { seed }

    it "pages through entries in insertion order" do
      expect(products.count).to eq(3)
      expect(titles(products.page(1, per_page: 2))).to eq(["Brass Wall Light", "Glass Pendant"])
      expect(titles(products.page(2, per_page: 2))).to eq(["Hiking Boots"])
      expect(products.page(3, per_page: 2)).to eq([])
    end
  end
end
