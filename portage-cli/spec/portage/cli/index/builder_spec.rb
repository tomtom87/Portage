require "spec_helper"
require "tmpdir"

RSpec.describe Portage::Cli::Index::Builder do
  around do |example|
    Dir.mktmpdir do |dir|
      @stores_path = File.join(dir, "stores.json")
      @products_path = File.join(dir, "products.json")
      example.run
    end
  end

  let(:stores) { Portage::Cli::Index::Store.new(path: @stores_path) }
  let(:products) { Portage::Cli::Index::ProductStore.new(path: @products_path) }
  let(:cache) { instance_double(Portage::Cli::ProbeCache, fetch: nil, record: true) }

  def fake_source(name, sightings)
    double("Source", name: name, candidates: sightings)
  end

  def session(caps) = instance_double(Portage::Ucp::Client::Session, capabilities: caps)

  def builder(sources:, out: nil, **opts)
    described_class.new(stores: stores, products: products, cache: cache, sources: sources, throttle: 0, out: out,
                        **opts)
  end

  let(:full_caps) { %w[dev.ucp.shopping.catalog dev.ucp.shopping.cart dev.ucp.shopping.checkout] }

  describe "#build" do
    it "stores a newly verified origin with its capabilities, categories and source" do
      source = fake_source("shopify_catalog",
                           [{ origin: "https://shop.example", url: "https://shop.example/products/x",
                              title: "Trail Boots", brand: nil, gtin: nil }])
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session(full_caps))

      result = builder(sources: [source]).build

      entry = stores.find("https://shop.example")
      expect(entry).to include("platform" => "shopify", "capabilities" => %w[catalog cart checkout],
                               "sources" => ["shopify_catalog"], "handoff_only" => false)
      expect(entry["categories"]).to be_a(Hash)
      expect(result[:verified]).to eq(["https://shop.example"])
      expect(result[:candidates]).to eq(1)
    end

    it "never adds a candidate whose probe fails" do
      source = fake_source("shopify_catalog", [{ origin: "https://dead.example", url: nil, title: nil, brand: nil,
                                                 gtin: nil }])
      allow(Portage::Ucp::Client).to receive(:discover).and_raise(StandardError, "no manifest")

      builder(sources: [source]).build

      expect(stores.find("https://dead.example")).to be_nil
    end

    it "skips the probe entirely for an origin the cache already marked a miss" do
      allow(cache).to receive(:fetch).with("https://dead.example").and_return(false)
      allow(Portage::Ucp::Client).to receive(:discover)
      source = fake_source("stores_file", [{ origin: "https://dead.example", url: nil, title: nil, brand: nil,
                                             gtin: nil }])

      builder(sources: [source]).build

      expect(Portage::Ucp::Client).not_to have_received(:discover)
    end

    it "records a product sighting only for an origin that verified" do
      source = fake_source("shopify_catalog",
                           [{ origin: "https://shop.example", url: "https://shop.example/products/x",
                              title: "Trail Boots", brand: "Lems", gtin: nil }])
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session(full_caps))

      builder(sources: [source]).build

      entry = products.all.find { |p| p["title"] == "Trail Boots" }
      expect(entry).not_to be_nil
      expect(entry["stores"].map { |s| s["origin"] }).to eq(["https://shop.example"])
      # Phase 3: products carry the source that saw them, so Index::Exporter
      # can tell a real source's product from a browser-import one.
      expect(entry["sources"]).to eq(["shopify_catalog"])
    end

    it "never stores a price or stock field on a product entry" do
      source = fake_source("shopify_catalog",
                           [{ origin: "https://shop.example", url: nil, title: "Trail Boots", brand: nil,
                              gtin: nil }])
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session(full_caps))

      builder(sources: [source]).build

      entry = products.all.first
      expect(entry.keys).not_to include("price", "amount", "stock")
    end

    it "merges into an existing entry (adding a source/category) without re-probing it" do
      stores.upsert("https://shop.example", sources: ["stores_file"], categories: {}, last_verified: 1,
                                            handoff_only: false)
      source = fake_source("shopify_catalog", [{ origin: "https://shop.example", url: nil, title: "Trail Boots",
                                                 brand: nil, gtin: nil }])
      allow(Portage::Ucp::Client).to receive(:discover)

      builder(sources: [source]).build

      expect(Portage::Ucp::Client).not_to have_received(:discover)
      expect(stores.find("https://shop.example")["sources"]).to contain_exactly("stores_file", "shopify_catalog")
    end

    it "runs multiple sources and tags each sighting with its own source name" do
      a = fake_source("shopify_catalog", [{ origin: "https://a.example", url: nil, title: nil, brand: nil,
                                            gtin: nil }])
      b = fake_source("stores_file", [{ origin: "https://b.example", url: nil, title: nil, brand: nil, gtin: nil }])
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session(full_caps))

      result = builder(sources: [a, b]).build

      expect(result[:sources_run]).to eq(%w[shopify_catalog stores_file])
      expect(stores.all.map { |e| e["origin"] }).to contain_exactly("https://a.example", "https://b.example")
    end

    it "doesn't let one source's own error take out the others" do
      broken = double("Source", name: "broken")
      allow(broken).to receive(:candidates).and_raise(StandardError, "boom")
      ok = fake_source("stores_file", [{ origin: "https://ok.example", url: nil, title: nil, brand: nil,
                                         gtin: nil }])
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session(full_caps))

      result = builder(sources: [broken, ok]).build

      expect(stores.find("https://ok.example")).not_to be_nil
      expect(result[:candidates]).to eq(1)
    end

    it "writes nothing under --dry-run, but still reports what it found" do
      source = fake_source("shopify_catalog", [{ origin: "https://shop.example", url: nil, title: "Trail Boots",
                                                 brand: nil, gtin: nil }])
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session(full_caps))

      result = builder(sources: [source]).build(dry_run: true)

      expect(stores.all).to eq([])
      expect(products.all).to eq([])
      expect(result[:verified]).to eq(["https://shop.example"])
    end

    it "caps new-origin probes at max_new_probes and reports it was capped" do
      sightings = (1..3).map { |i| { origin: "https://s#{i}.example", url: nil, title: nil, brand: nil, gtin: nil } }
      source = fake_source("stores_file", sightings)
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session(full_caps))

      result = builder(sources: [source], max_new_probes: 1).build

      expect(result[:new_origins_checked].length).to eq(1)
      expect(result[:capped]).to be true
    end

    it "passes the queries option straight through to every source" do
      source = double("Source", name: "shopify_catalog")
      allow(source).to receive(:candidates).with(queries: ["boots"]).and_return([])

      builder(sources: [source]).build(queries: ["boots"])

      expect(source).to have_received(:candidates).with(queries: ["boots"])
    end
  end

  describe "#build with --export" do
    it "also writes a PR-ready export when export: is given" do
      source = fake_source("shopify_catalog", [{ origin: "https://shop.example", url: nil, title: "Trail Boots",
                                                 brand: nil, gtin: nil }])
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session(full_caps))

      Dir.mktmpdir do |export_dir|
        result = builder(sources: [source]).build(export: export_dir)

        expect(result[:exported]).to include(stores: 1, products: 1, dir: export_dir)
        expect(JSON.parse(File.read(File.join(export_dir, "stores.json")))).to have_key("https://shop.example")
      end
    end

    it "doesn't export when export: is nil" do
      source = fake_source("shopify_catalog", [{ origin: "https://shop.example", url: nil, title: nil, brand: nil,
                                                 gtin: nil }])
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session(full_caps))

      result = builder(sources: [source]).build

      expect(result).not_to have_key(:exported)
    end
  end

  describe "#refresh" do
    it "refreshes the known-stores cache unconditionally" do
      known_cache = instance_double(Portage::Cli::Index::KnownCache, refresh!: true)

      described_class.new(stores: stores, products: products, cache: cache, sources: [], throttle: 0,
                          known_cache: known_cache).refresh

      expect(known_cache).to have_received(:refresh!)
    end

    it "doesn't refresh the known-stores cache under --dry-run" do
      known_cache = instance_double(Portage::Cli::Index::KnownCache)
      allow(known_cache).to receive(:refresh!)

      described_class.new(stores: stores, products: products, cache: cache, sources: [], throttle: 0,
                          known_cache: known_cache).refresh(dry_run: true)

      expect(known_cache).not_to have_received(:refresh!)
    end

    it "re-verifies a stale entry and bumps last_verified when it still answers" do
      stores.upsert("https://old.example", capabilities: [], last_verified: Time.now.to_i - (8 * 24 * 60 * 60))
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session(full_caps))

      builder(sources: []).refresh

      entry = stores.find("https://old.example")
      expect(entry["last_verified"]).to be_within(5).of(Time.now.to_i)
      expect(entry["capabilities"]).to eq(%w[catalog cart checkout])
    end

    it "leaves a stale entry's last_verified untouched when it no longer answers" do
      old_time = Time.now.to_i - (8 * 24 * 60 * 60)
      stores.upsert("https://old.example", capabilities: [], last_verified: old_time)
      allow(Portage::Ucp::Client).to receive(:discover).and_raise(StandardError, "gone")

      builder(sources: []).refresh

      expect(stores.find("https://old.example")["last_verified"]).to eq(old_time)
    end

    it "doesn't re-verify an entry that's still fresh" do
      stores.upsert("https://fresh.example", capabilities: [], last_verified: Time.now.to_i - 60)
      allow(Portage::Ucp::Client).to receive(:discover)

      builder(sources: []).refresh

      expect(Portage::Ucp::Client).not_to have_received(:discover)
    end
  end

  describe "#add" do
    it "verifies and stores a URL directly, marked not hand-off-only" do
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session(full_caps))

      result = builder(sources: []).add("https://shop.example/anything")

      expect(result[:added]).to be true
      expect(stores.find("https://shop.example")).to include("handoff_only" => false)
    end

    it "still stores an origin that doesn't answer UCP, marked hand-off-only" do
      allow(Portage::Ucp::Client).to receive(:discover).and_raise(StandardError, "404")

      result = builder(sources: []).add("https://shop.example")

      expect(result[:added]).to be true
      expect(stores.find("https://shop.example")).to include("handoff_only" => true)
    end

    it "refuses a URL that doesn't parse as http(s)" do
      result = builder(sources: []).add("not a url")

      expect(result[:added]).to be false
      expect(stores.all).to eq([])
    end
  end

  describe "#remove" do
    it "removes a known host and reports it" do
      stores.upsert("https://shop.example", last_verified: 1)

      result = builder(sources: []).remove("shop.example")

      expect(result[:removed]).to be true
      expect(stores.find("https://shop.example")).to be_nil
    end

    it "reports nothing removed for an unknown host" do
      expect(builder(sources: []).remove("nope.example")[:removed]).to be false
    end
  end

  describe "Tier C: hand-off-only hosts (docs/plans/buy-skill-and-local-browser.md Phase 5)" do
    let(:handoff_only) { Portage::Cli::HandoffOnly.new(config: Portage::Cli::Config.load) }

    before { Portage::Cli::Config.load.set("handoff_only_hosts", ["amazon.co.uk"]) }

    it "#build never probes a new hand-off-only origin, and records it as such" do
      expect(Portage::Ucp::Client).not_to receive(:discover)
      source = fake_source("shopify_catalog", [{ origin: "https://www.amazon.co.uk",
                                                 url: "https://www.amazon.co.uk/dp/x", title: "Kettle", brand: nil,
                                                 gtin: nil }])

      result = builder(sources: [source], handoff_only: handoff_only).build

      entry = stores.find("https://www.amazon.co.uk")
      expect(entry).to include("handoff_only" => true, "capabilities" => [])
      expect(result[:verified]).to eq([])
    end

    it "#add never probes a hand-off-only URL either" do
      expect(Portage::Ucp::Client).not_to receive(:discover)

      result = builder(sources: [], handoff_only: handoff_only).add("https://www.amazon.co.uk/anything")

      expect(result[:added]).to be true
      expect(stores.find("https://www.amazon.co.uk")).to include("handoff_only" => true)
    end

    it "#refresh never re-probes an existing hand-off-only entry" do
      stores.upsert("https://www.amazon.co.uk", handoff_only: true, last_verified: 1)
      expect(Portage::Ucp::Client).not_to receive(:discover)

      builder(sources: [], handoff_only: handoff_only).refresh
    end

    # Regression: #reverify_stale used to skip by the entry's *stored*
    # `handoff_only` flag rather than the live config — but a store whose
    # UCP probe simply failed (not a Tier C host at all) is stored
    # `handoff_only: true` too (#store_new/#store_manual), so it would
    # never be re-verified again even though it isn't on the hand-off-only
    # list and might come online.
    it "#refresh still re-probes a stale entry stored handoff_only: true whose host isn't on the Tier C list" do
      stores.upsert("https://dead.example", handoff_only: true, last_verified: 1)
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session(full_caps))

      builder(sources: [], handoff_only: handoff_only).refresh

      expect(Portage::Ucp::Client).to have_received(:discover).with("https://dead.example", anything)
      expect(stores.find("https://dead.example")).to include("capabilities" => %w[catalog cart checkout])
    end

    # Regression: a store recorded (and verified) *before* the user added
    # its host to handoff_only_hosts was stored `handoff_only: false`, and
    # the old flag-based skip would keep probing it forever — the live
    # config, not the stale stored flag, has to decide.
    it "#refresh never probes a stale entry stored handoff_only: false whose host is now on the Tier C list, " \
       "and flips its stored flag" do
      stores.upsert("https://www.amazon.co.uk", handoff_only: false, capabilities: %w[catalog], last_verified: 1)
      expect(Portage::Ucp::Client).not_to receive(:discover)

      builder(sources: [], handoff_only: handoff_only).refresh

      expect(stores.find("https://www.amazon.co.uk")).to include("handoff_only" => true)
    end

    it "#refresh does nothing to a hand-off-only entry under --dry-run" do
      stores.upsert("https://www.amazon.co.uk", handoff_only: false, last_verified: 1)
      expect(Portage::Ucp::Client).not_to receive(:discover)

      builder(sources: [], handoff_only: handoff_only).refresh(dry_run: true)

      expect(stores.find("https://www.amazon.co.uk")).to include("handoff_only" => false)
    end
  end
end
