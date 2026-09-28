require "spec_helper"
require "tmpdir"

RSpec.describe Portage::Cli::Index::ProductStore do
  around do |example|
    Dir.mktmpdir do |dir|
      @path = File.join(dir, "products.json")
      example.run
    end
  end

  let(:products) { described_class.new(path: @path) }

  it "upserts a new product with its first store sighting" do
    products.upsert("title:trail-boots", origin: "https://shop.example", seen_at: 1000, title: "Trail Boots",
                                         brand: "Lems", gtin: nil, category: "166")

    entry = products.find("title:trail-boots")
    expect(entry).to include("title" => "Trail Boots", "brand" => "Lems", "category" => "166")
    expect(entry["stores"]).to eq([{ "origin" => "https://shop.example", "last_seen" => 1000 }])
  end

  it "never stores a price or stock field even if a caller tried to pass one" do
    products.upsert("title:trail-boots", origin: "https://shop.example", seen_at: 1000, title: "Trail Boots")

    expect(products.find("title:trail-boots").keys).not_to include("price", "amount", "stock", "available")
  end

  it "adds a second store's sighting without dropping the first" do
    products.upsert("title:trail-boots", origin: "https://a.example", seen_at: 1000, title: "Trail Boots")
    products.upsert("title:trail-boots", origin: "https://b.example", seen_at: 2000, title: "Trail Boots")

    origins = products.find("title:trail-boots")["stores"].map { |s| s["origin"] }
    expect(origins).to contain_exactly("https://a.example", "https://b.example")
  end

  it "updates last_seen for the same origin rather than duplicating it" do
    products.upsert("title:trail-boots", origin: "https://a.example", seen_at: 1000, title: "Trail Boots")
    products.upsert("title:trail-boots", origin: "https://a.example", seen_at: 2000, title: "Trail Boots")

    stores = products.find("title:trail-boots")["stores"]
    expect(stores.length).to eq(1)
    expect(stores.first["last_seen"]).to eq(2000)
  end

  it "records a different title at another store as an alias, not a replacement" do
    products.upsert("gtin:123", origin: "https://a.example", seen_at: 1000, title: "Trail Boots", gtin: "123")
    products.upsert("gtin:123", origin: "https://b.example", seen_at: 1000, title: "Trailblazer Boot", gtin: "123")

    entry = products.find("gtin:123")
    expect(entry["title"]).to eq("Trailblazer Boot")
    expect(entry["aliases"]).to eq(["Trail Boots"])
  end

  it "persists across instances" do
    products.upsert("title:x", origin: "https://a.example", seen_at: 1, title: "X")

    expect(described_class.new(path: @path).find("title:x")).not_to be_nil
  end

  it "tolerates a corrupt products.json rather than raising" do
    FileUtils.mkdir_p(File.dirname(@path))
    File.write(@path, "not json")

    expect(products.all).to eq([])
  end
end
