require "spec_helper"
require "tmpdir"

RSpec.describe Portage::Cli::Index::Store do
  around do |example|
    Dir.mktmpdir do |dir|
      @path = File.join(dir, "stores.json")
      example.run
    end
  end

  let(:store) { described_class.new(path: @path) }

  it "has no entries and doesn't exist before anything is written" do
    expect(store.all).to eq([])
    expect(store.exists?).to be false
    expect(store.find("https://shop.example")).to be_nil
  end

  it "upserts a new entry and persists it across instances" do
    store.upsert("https://shop.example", platform: "shopify", capabilities: %w[catalog cart checkout],
                                         last_verified: 1000, handoff_only: false)

    reloaded = described_class.new(path: @path)
    expect(reloaded.find("https://shop.example")).to include("origin" => "https://shop.example",
                                                             "platform" => "shopify", "last_verified" => 1000)
    expect(reloaded.exists?).to be true
  end

  it "merges fields onto an existing entry rather than replacing it" do
    store.upsert("https://shop.example", sources: ["shopify_catalog"], last_verified: 1000)
    store.upsert("https://shop.example", categories: { "166" => 2 })

    entry = store.find("https://shop.example")
    expect(entry).to include("sources" => ["shopify_catalog"], "categories" => { "166" => 2 },
                             "last_verified" => 1000)
  end

  it "removes every entry whose host matches" do
    store.upsert("https://shop.example", last_verified: 1)
    store.upsert("https://other.example", last_verified: 1)

    expect(store.remove("shop.example")).to eq(1)
    expect(store.all.map { |e| e["origin"] }).to eq(["https://other.example"])
  end

  it "returns 0 from remove when the host isn't in the index" do
    expect(store.remove("nope.example")).to eq(0)
  end

  it "reports the age of the oldest verified entry" do
    now = Time.now
    store.upsert("https://old.example", last_verified: (now - 10).to_i)
    store.upsert("https://new.example", last_verified: (now - 2).to_i)

    expect(store.oldest_verified_age(now: now)).to be_within(1).of(10)
  end

  it "returns nil age when the index is empty" do
    expect(store.oldest_verified_age).to be_nil
  end

  it "tolerates a corrupt stores.json rather than raising" do
    FileUtils.mkdir_p(File.dirname(@path))
    File.write(@path, "not json")

    expect(store.all).to eq([])
  end
end
