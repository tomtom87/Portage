require "spec_helper"
require "tmpdir"

RSpec.describe Portage::Cli::Index::Exporter do
  around do |example|
    Dir.mktmpdir do |dir|
      @stores_path = File.join(dir, "stores.json")
      @products_path = File.join(dir, "products.json")
      @export_dir = File.join(dir, "export")
      example.run
    end
  end

  let(:stores) { Portage::Cli::Index::Store.new(path: @stores_path) }
  let(:products) { Portage::Cli::Index::ProductStore.new(path: @products_path) }
  let(:exporter) { described_class.new(stores: stores, products: products) }

  def exported_stores
    JSON.parse(File.read(File.join(@export_dir, "stores.json")))
  end

  def exported_products
    JSON.parse(File.read(File.join(@export_dir, "products.json")))
  end

  it "exports a store found by a real source, sources and last_verified intact" do
    stores.upsert("https://shop.example", sources: ["shopify_catalog"], last_verified: 1000,
                                          capabilities: %w[catalog], handoff_only: false)

    result = exporter.export(@export_dir)

    expect(result).to eq({ dir: @export_dir, stores: 1, products: 0 })
    expect(exported_stores["https://shop.example"]).to include("sources" => ["shopify_catalog"],
                                                               "last_verified" => 1000)
  end

  it "never exports a store whose only source is browsing history/bookmarks" do
    stores.upsert("https://personal.example", sources: ["browser"], last_verified: 1000)

    exporter.export(@export_dir)

    expect(exported_stores).to eq({})
  end

  it "strips 'browser' out of a mixed-source store's sources rather than dropping the whole entry" do
    stores.upsert("https://mixed.example", sources: %w[shopify_catalog browser], last_verified: 1000)

    exporter.export(@export_dir)

    expect(exported_stores["https://mixed.example"]["sources"]).to eq(["shopify_catalog"])
  end

  it "exports a product seen at a surviving store" do
    stores.upsert("https://shop.example", sources: ["shopify_catalog"], last_verified: 1000)
    products.upsert("title:x", origin: "https://shop.example", seen_at: 1000, title: "X")

    exporter.export(@export_dir)

    expect(exported_products["title:x"]["stores"]).to eq([{ "origin" => "https://shop.example",
                                                            "last_seen" => 1000 }])
  end

  it "never exports a product only ever seen at a browser-only store" do
    stores.upsert("https://personal.example", sources: ["browser"], last_verified: 1000)
    products.upsert("title:x", origin: "https://personal.example", seen_at: 1000, title: "X")

    exporter.export(@export_dir)

    expect(exported_products).to eq({})
  end

  it "trims a product's stores to just the surviving origins when it has a mix" do
    stores.upsert("https://real.example", sources: ["shopify_catalog"], last_verified: 1000)
    stores.upsert("https://personal.example", sources: ["browser"], last_verified: 1000)
    products.upsert("title:x", origin: "https://real.example", seen_at: 1000, title: "X")
    products.upsert("title:x", origin: "https://personal.example", seen_at: 2000, title: "X")

    exporter.export(@export_dir)

    expect(exported_products["title:x"]["stores"]).to eq([{ "origin" => "https://real.example",
                                                            "last_seen" => 1000 }])
  end

  describe "browser-import labels (docs/plans/buy-skill-and-local-browser.md Phase 3)" do
    it "never exports a store found only in history and/or bookmarks" do
      stores.upsert("https://history.example", sources: ["history"], last_verified: 1000)
      stores.upsert("https://bookmark.example", sources: ["bookmark"], last_verified: 1000)
      stores.upsert("https://both.example", sources: %w[bookmark history], last_verified: 1000)

      result = exporter.export(@export_dir)

      expect(result[:stores]).to eq(0)
      expect(exported_stores).to eq({})
    end

    it "strips history/bookmark from a store a real source also found" do
      stores.upsert("https://mixed.example", sources: %w[shopify_catalog history bookmark], last_verified: 1000)

      exporter.export(@export_dir)

      expect(exported_stores["https://mixed.example"]["sources"]).to eq(["shopify_catalog"])
    end

    it "never exports a product page kept by --include-product-pages, even at a store a real source found" do
      stores.upsert("https://mixed.example", sources: %w[shopify_catalog history], last_verified: 1000)
      products.upsert("title:looked-at", origin: "https://mixed.example", seen_at: 1000, title: "Looked at",
                                         sources: ["history"])
      products.upsert("title:catalog", origin: "https://mixed.example", seen_at: 1000, title: "Catalog",
                                       sources: ["shopify_catalog"])

      exporter.export(@export_dir)

      expect(exported_products.keys).to eq(["title:catalog"])
      expect(exported_products["title:catalog"]["sources"]).to eq(["shopify_catalog"])
    end

    it "strips the personal label from a product both a real source and the browser saw" do
      stores.upsert("https://shop.example", sources: ["shopify_catalog"], last_verified: 1000)
      products.upsert("title:x", origin: "https://shop.example", seen_at: 1000, title: "X", sources: ["bookmark"])
      products.upsert("title:x", origin: "https://shop.example", seen_at: 2000, title: "X",
                                 sources: ["shopify_catalog"])

      exporter.export(@export_dir)

      expect(exported_products["title:x"]["sources"]).to eq(["shopify_catalog"])
    end

    it "still exports a store with an empty sources list, as before" do
      stores.upsert("https://legacy.example", sources: [], last_verified: 1000)

      exporter.export(@export_dir)

      expect(exported_stores.keys).to eq(["https://legacy.example"])
    end
  end
end
