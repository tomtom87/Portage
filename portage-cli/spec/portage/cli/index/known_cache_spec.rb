require "spec_helper"
require "tmpdir"

RSpec.describe Portage::Cli::Index::KnownCache do
  around do |example|
    Dir.mktmpdir do |dir|
      @stores_path = File.join(dir, "known-stores.json")
      @products_path = File.join(dir, "known-products.json")
      example.run
    end
  end

  let(:cache) do
    described_class.new(stores_path: @stores_path, products_path: @products_path,
                        stores_url: "https://example.test/stores.json",
                        products_url: "https://example.test/products.json")
  end

  let(:stores_body) { { "https://a.example" => { "origin" => "https://a.example", "sources" => ["shopify_catalog"] } } }
  let(:products_body) { { "title:x" => { "key" => "title:x", "title" => "X" } } }

  it "has no entries and doesn't exist before anything is fetched" do
    expect(cache.stores).to eq({})
    expect(cache.products).to eq({})
    expect(cache.exists?).to be false
    expect(cache.age).to be_nil
  end

  it "fetches and caches both files on a successful refresh" do
    stub_request(:get, "https://example.test/stores.json").to_return(body: stores_body.to_json, status: 200)
    stub_request(:get, "https://example.test/products.json").to_return(body: products_body.to_json, status: 200)

    expect(cache.refresh!).to be true
    expect(cache.stores).to eq(stores_body)
    expect(cache.products).to eq(products_body)
    expect(cache.exists?).to be true
  end

  it "strips a price/amount/stock field from a fetched entry before caching it" do
    tainted = { "gtin:1" => { "key" => "gtin:1", "title" => "X", "price" => 999, "amount" => 5, "stock" => 3 } }
    stub_request(:get, "https://example.test/stores.json").to_return(body: "{}", status: 200)
    stub_request(:get, "https://example.test/products.json").to_return(body: tainted.to_json, status: 200)

    cache.refresh!

    expect(cache.products["gtin:1"].keys).not_to include("price", "amount", "stock")
  end

  it "rejects a fetch that isn't a Hash-of-Hashes rather than caching it" do
    stub_request(:get, "https://example.test/stores.json").to_return(body: "[1,2,3]", status: 200)
    stub_request(:get, "https://example.test/products.json").to_return(body: "{}", status: 200)

    cache.refresh!

    expect(cache.stores).to eq({})
  end

  it "swallows a network failure rather than raising" do
    stub_request(:get, "https://example.test/stores.json").to_timeout
    stub_request(:get, "https://example.test/products.json").to_timeout

    expect(cache.refresh!).to be false
    expect(cache.exists?).to be false
  end

  it "swallows a non-200 response" do
    stub_request(:get, "https://example.test/stores.json").to_return(status: 500)
    stub_request(:get, "https://example.test/products.json").to_return(status: 500)

    expect(cache.refresh!).to be false
  end

  it "only fetches when there's no cache yet — fetch_if_missing! is a no-op once a cache exists" do
    stub_request(:get, "https://example.test/stores.json").to_return(body: stores_body.to_json, status: 200)
    stub_request(:get, "https://example.test/products.json").to_return(body: products_body.to_json, status: 200)
    cache.refresh!

    expect(a_request(:get, "https://example.test/stores.json")).to have_been_made.once
    expect(cache.fetch_if_missing!).to be false
    expect(a_request(:get, "https://example.test/stores.json")).to have_been_made.once
  end

  it "is stale with no cache at all, and once older than 7 days" do
    expect(cache.stale?).to be true

    stub_request(:get, "https://example.test/stores.json").to_return(body: "{}", status: 200)
    stub_request(:get, "https://example.test/products.json").to_return(body: "{}", status: 200)
    cache.refresh!

    expect(cache.stale?(now: Time.now + (8 * 24 * 60 * 60))).to be true
    expect(cache.stale?(now: Time.now + 60)).to be false
  end

  it "tolerates a corrupt cache file rather than raising" do
    FileUtils.mkdir_p(File.dirname(@stores_path))
    File.write(@stores_path, "not json")

    expect(cache.stores).to eq({})
  end
end
