require "spec_helper"
require "json"
require "tmpdir"

# Index::Builder with storefront_products (docs/plans/local-catalogue.md
# Phase 2): the source hands back product sightings carrying the mapped
# UCP subset, plus one store sighting carrying the crawl note, and the
# Builder persists both through its one write path.
RSpec.describe Portage::Cli::Index::Builder do
  around do |example|
    Dir.mktmpdir do |dir|
      @stores_path = File.join(dir, "stores.json")
      @products_path = File.join(dir, "products.json")
      example.run
    end
  end

  let(:origin) { "https://shop.example" }
  let(:stores) { Portage::Cli::Index::Store.new(path: @stores_path) }
  let(:products) { Portage::Cli::Index::ProductStore.new(path: @products_path) }
  let(:cache) { instance_double(Portage::Cli::ProbeCache, fetch: nil, record: true) }
  let(:handoff_only) { instance_double(Portage::Cli::HandoffOnly, host?: false) }
  let(:full_caps) { %w[dev.ucp.shopping.catalog dev.ucp.shopping.cart dev.ucp.shopping.checkout] }

  def product_sighting(title, handle)
    { origin: origin, url: "#{origin}/products/#{handle}", title: title, brand: "Yard", gtin: nil,
      categories: %w[594], product: { handle: handle, url: "#{origin}/products/#{handle}",
                                      image_url: "https://cdn.example/#{handle}.webp",
                                      options: [{ "name" => "Finish", "values" => [{ "label" => "Brass" }] }],
                                      variant_ids: ["gid://shopify/ProductVariant/1"] } }
  end

  def crawl_sightings(*titles)
    titles = titles.flatten
    titles.each_with_index.map { |t, i| product_sighting(t, "p#{i}") } +
      [{ origin: origin, url: nil, title: nil, brand: nil, gtin: nil,
         store_fields: { platform: "shopify",
                         crawl: { "status" => "ok", "reason" => nil, "pages" => 1, "products" => titles.length,
                                  "at" => 5 } } }]
  end

  def storefront(sightings) = double("Source", name: "storefront_products", candidates: sightings)

  def builder(sources:, **opts)
    described_class.new(stores: stores, products: products, cache: cache, sources: sources, throttle: 0, out: nil,
                        handoff_only: handoff_only, **opts)
  end

  before { stores.upsert(origin, sources: ["manual"], categories: {}, last_verified: 1, handoff_only: false) }

  describe "#build --sources storefront_products" do
    it "persists the mapped product fields, the source's categories and no price" do
      builder(sources: [storefront(crawl_sightings("Brass Wall Light"))]).build

      entry = products.find("title:yard-brass-wall-light")
      expect(entry).to include("title" => "Brass Wall Light", "brand" => "Yard", "category" => "594",
                               "handle" => "p0", "url" => "#{origin}/products/p0",
                               "image_url" => "https://cdn.example/p0.webp",
                               "options" => [{ "name" => "Finish", "values" => [{ "label" => "Brass" }] }],
                               "variant_ids" => ["gid://shopify/ProductVariant/1"],
                               "sources" => ["storefront_products"])
      expect(JSON.generate(entry)).not_to match(/price|availab/)
    end

    it "records the crawl note and platform on the store row, and the source in its sources" do
      builder(sources: [storefront(crawl_sightings("Brass Wall Light"))]).build

      expect(stores.find(origin)).to include(
        "platform" => "shopify", "sources" => %w[manual storefront_products],
        "crawl" => { "status" => "ok", "reason" => nil, "pages" => 1, "products" => 1, "at" => 5 }
      )
    end

    it "upserts on a re-crawl rather than duplicating" do
      2.times { builder(sources: [storefront(crawl_sightings("Brass Wall Light", "Glass Pendant"))]).build }

      expect(products.all.length).to eq(2)
      expect(products.find("title:yard-glass-pendant")["stores"].map { |s| s["origin"] }).to eq([origin])
    end

    it "writes product sightings in batches through upsert_many" do
      allow(products).to receive(:upsert_many).and_call_original
      sightings = crawl_sightings(Array.new(described_class::WRITE_BATCH + 1) { |i| "Lamp #{i}" })

      result = builder(sources: [storefront(sightings)]).build

      expect(products).to have_received(:upsert_many).twice
      expect(result[:products_added]).to eq(described_class::WRITE_BATCH + 1)
      expect(products.all.length).to eq(described_class::WRITE_BATCH + 1)
    end

    it "writes nothing under --dry-run" do
      builder(sources: [storefront(crawl_sightings("Brass Wall Light"))]).build(dry_run: true)

      expect(products.all).to eq([])
      expect(stores.find(origin)).not_to have_key("crawl")
    end
  end

  describe "#add with crawl:" do
    let(:crawler) { instance_double(Portage::Cli::Index::Sources::StorefrontProducts, name: "storefront_products") }

    before do
      allow(Portage::Cli::Index::Sources::StorefrontProducts).to receive(:new)
        .with(stores: stores, handoff_only: handoff_only).and_return(crawler)
      allow(Portage::Ucp::Client).to receive(:discover)
        .and_return(instance_double(Portage::Ucp::Client::Session, capabilities: full_caps))
    end

    it "crawls the added origin's catalogue into the index" do
      allow(crawler).to receive(:crawl).with(origin, platform: nil).and_return(crawl_sightings("Brass Wall Light"))

      result = builder(sources: []).add("#{origin}/collections/all", crawl: true)

      expect(result).to include(added: true, crawl: include("status" => "ok", "products" => 1))
      expect(result[:message]).to include("1 product")
      expect(products.find("title:yard-brass-wall-light")).not_to be_nil
    end

    it "doesn't crawl unless asked" do
      allow(crawler).to receive(:crawl)

      builder(sources: []).add(origin)

      expect(crawler).not_to have_received(:crawl)
    end

    it "never crawls a hand-off-only origin, even when asked" do
      allow(handoff_only).to receive(:host?).and_return(true)
      allow(crawler).to receive(:crawl)

      builder(sources: []).add(origin, crawl: true)

      expect(crawler).not_to have_received(:crawl)
    end
  end
end
