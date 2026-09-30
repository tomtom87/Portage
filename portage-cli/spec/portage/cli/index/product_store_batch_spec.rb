require "spec_helper"
require "tmpdir"

RSpec.describe Portage::Cli::Index::ProductStore, "#upsert_many" do
  around do |example|
    Dir.mktmpdir do |dir|
      @path = File.join(dir, "products.json")
      example.run
    end
  end

  let(:products) { described_class.new(path: @path) }

  def row(key, **over)
    { key: key, origin: "https://a.example", seen_at: 1, title: key }.merge(over)
  end

  it "writes every row and returns the merged entries" do
    result = products.upsert_many([row("title:a"), row("title:b", brand: "Lems")])

    expect(result.map { |e| e["key"] }).to eq(%w[title:a title:b])
    expect(products.all.map { |e| e["key"] }).to eq(%w[title:a title:b])
    expect(products.find("title:b")["brand"]).to eq("Lems")
  end

  it "merges exactly like #upsert, including repeats of one key inside a batch" do
    products.upsert_many([row("gtin:1", title: "Trail Boots", sources: ["one"]),
                          row("gtin:1", origin: "https://b.example", seen_at: 2, title: "Trailblazer",
                                        sources: ["two"])])

    entry = products.find("gtin:1")
    expect(entry).to include("title" => "Trailblazer", "aliases" => ["Trail Boots"], "sources" => %w[one two])
    expect(entry["stores"].map { |s| s["origin"] }).to eq(%w[https://a.example https://b.example])
  end

  it "is atomic: a failure halfway leaves nothing from the batch behind" do
    products.upsert("title:existing", origin: "https://a.example", seen_at: 1, title: "Before")

    expect do
      products.upsert_many([row("title:existing", title: "After"), row("title:new"), { key: "title:bad" }])
    end.to raise_error(KeyError)

    expect(products.all.map { |e| e["key"] }).to eq(["title:existing"])
    expect(products.find("title:existing")["title"]).to eq("Before")
  end

  it "does nothing for an empty batch" do
    expect(products.upsert_many([])).to eq([])
    expect(products.exists?).to be false
  end
end
