require "spec_helper"
require "tmpdir"
require_relative "fixtures"

RSpec.describe Portage::Cli::BrowserImport::Importer do
  include BrowserImportFixtures

  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      @root = File.join(dir, "Chrome")
      example.run
    end
  end

  let(:stores) { Portage::Cli::Index::Store.new(path: File.join(@dir, "stores.json")) }
  let(:products) { Portage::Cli::Index::ProductStore.new(path: File.join(@dir, "products.json")) }
  let(:known_cache) do
    Portage::Cli::Index::KnownCache.new(stores_path: File.join(@dir, "known-stores.json"),
                                        products_path: File.join(@dir, "known-products.json"))
  end
  let(:probe_cache) { Portage::Cli::ProbeCache.new(path: File.join(@dir, "discovery-cache.json")) }
  let(:ucp_origins) { [] }
  let(:probed) { [] }
  let(:discover) do
    lambda do |origin|
      probed << origin
      ucp_origins.include?(origin) ? Struct.new(:capabilities).new(%w[dev.ucp.shopping.catalog]) : nil
    end
  end
  let(:prober) { Portage::Cli::BrowserImport::Prober.new(cache: probe_cache, discover: discover, throttle: 0) }

  def fake_profile!
    FileUtils.mkdir_p(File.join(@root, "Default"))
    File.write(File.join(@root, "Default", "History"), "")
  end

  def importer(rows, **opts)
    fake_profile!
    reader = double("Reader", history: rows.select { |r| r[:kind] == "history" },
                              bookmarks: rows.select { |r| r[:kind] == "bookmark" })
    described_class.new(stores: stores, products: products, known_cache: known_cache, prober: prober,
                        readers: ->(_family) { reader }, **opts)
  end

  def row(url, title: "", kind: "history", visits: 1, folder: "")
    { kind: kind, url: url, title: title, folder: folder, visits: visits }
  end

  def options(**overrides)
    described_class::Options.new(browser: "chrome", root: @root, **overrides)
  end

  describe "#plan" do
    it "keeps only domains that answer /.well-known/ucp, categorised from what the user looked at" do
      ucp_origins << "https://www.bootshop.example"
      rows = [row("https://www.bootshop.example/products/trail-runner", title: "Running Shoes", visits: 5),
              row("https://bootshop.example/", title: "Boot Shop", kind: "bookmark", folder: "Shoes"),
              row("https://blog.example/post", title: "My blog", visits: 9)]

      plan = importer(rows).plan(options)

      expect(plan[:kept].map { |e| e.slice(:domain, :origin, :verdict, :sources, :visits) })
        .to eq([{ domain: "bootshop.example", origin: "https://www.bootshop.example", verdict: "ucp",
                  sources: %w[bookmark history], visits: 6 }])
      expect(plan[:kept].first[:capabilities]).to eq(["catalog"])
      expect(plan[:kept].first[:categories]).not_to be_empty
      expect(plan[:kept].first[:category_names]).to all(be_a(String))
      expect(plan).to include(domains: 2, probed: 2, not_ucp: 1, rows: { history: 2, bookmark: 1 })
    end

    it "weights categories by visit count" do
      ucp_origins << "https://mixed.example"
      rows = [row("https://mixed.example/products/x", title: "Kitchen Knives", visits: 10),
              row("https://mixed.example/products/y", title: "Jewelry", visits: 1)]

      categories = importer(rows).plan(options)[:kept].first[:categories]

      kitchen = Portage::Cli::Classifier.categories_for("Kitchen Knives").first
      jewelry = Portage::Cli::Classifier.categories_for("Jewelry").first
      expect(categories[kitchen]).to eq(10)
      expect(categories[jewelry]).to eq(1)
      expect(categories.max_by { |_id, weight| weight }.first).to eq(kitchen)
    end

    it "keeps a domain whose titles match no category, uncategorised" do
      ucp_origins << "https://zqxw.example"

      entry = importer([row("https://zqxw.example/", title: "Zqxw")]).plan(options)[:kept].first

      expect(entry[:categories]).to eq({})
      expect(entry[:category_names]).to eq([])
    end

    it "decides obvious non-shops locally — they're never probed" do
      rows = [row("https://mail.google.com/mail/u/0"), row("https://www.paypal.com/"), row("http://localhost:3000/"),
              row("https://en.wikipedia.org/wiki/Boot"), row("chrome://settings/"), row("file:///etc/hosts")]

      plan = importer(rows).plan(options)

      expect(probed).to eq([])
      expect(plan[:skipped]).to eq("webmail" => 1, "bank" => 1, "local" => 1, "non_store" => 1)
      expect(plan[:kept]).to eq([])
    end

    it "never probes a domain already in the local index or the known-stores list" do
      stores.upsert("https://www.mine.example", sources: ["shopify_catalog"], capabilities: ["catalog"])
      File.write(File.join(@dir, "known-stores.json"),
                 JSON.generate("https://known.example" => { "origin" => "https://known.example",
                                                            "capabilities" => %w[catalog cart] }))

      plan = importer([row("https://mine.example/x"), row("https://known.example/y")]).plan(options)

      expect(probed).to eq([])
      expect(plan[:kept].to_h { |e| [e[:domain], [e[:verdict], e[:origin]]] })
        .to eq("mine.example" => ["indexed", "https://www.mine.example"],
               "known.example" => ["known", "https://known.example"])
      expect(plan).to include(already_indexed: 1, known: 1)
    end

    it "keeps a hand-off-only host without ever probing it (the Phase 5 seam; empty by default)" do
      rows = [row("https://www.bigmarket.example/dp/123", visits: 3)]

      expect(importer(rows).plan(options)[:kept]).to eq([])
      probed.clear

      plan = importer(rows, handoff_only_hosts: ["bigmarket.example"]).plan(options)

      expect(probed).to eq([])
      expect(plan[:kept].first).to include(domain: "bigmarket.example", verdict: "handoff_only", handoff_only: true)
    end

    it "spends no probe on a domain the probe cache already knows doesn't speak UCP" do
      probe_cache.record("https://dead.example", false)

      plan = importer([row("https://dead.example/")]).plan(options)

      expect(probed).to eq([])
      expect(plan).to include(cached_miss: 1, probed: 0)
    end

    it "caps probes at max_probes, spending them on the most-visited domains first" do
      rows = [row("https://a.example/", visits: 1), row("https://b.example/", visits: 5),
              row("https://c.example/", visits: 3)]

      plan = importer(rows).plan(options(max_probes: 2))

      expect(probed).to eq(["https://b.example", "https://c.example"])
      expect(plan).to include(probed: 2, unprobed: 1, capped: true)
    end

    it "defaults to 200 probes a run" do
      expect(options.max_probes).to eq(200)
      expect(described_class::MAX_PROBES).to eq(200)
    end

    it "skips the WebMCP preset check with no bridge, and keeps a match when one is injected" do
      rows = [row("https://webmcp.example/")]
      expect(importer(rows).plan(options)[:kept]).to eq([])

      matcher = ->(origin) { origin == "https://webmcp.example" ? "shopify" : nil }
      plan = importer(rows, webmcp_preset_for: matcher).plan(options)

      expect(plan[:kept].first).to include(verdict: "webmcp", webmcp_preset: "shopify")
    end

    it "drops domains the user excluded before anything else happens to them" do
      ucp_origins << "https://nope.example"

      plan = importer([row("https://www.nope.example/")]).plan(options(exclude: ["nope.example"]))

      expect(probed).to eq([])
      expect(plan[:skipped]).to eq("excluded" => 1)
    end

    it "keeps product pages only with include_product_pages" do
      ucp_origins << "https://shop.example"
      rows = [row("https://shop.example/products/trail-boots", title: "Trail Boots"),
              row("https://shop.example/pages/about", title: "About us")]

      expect(importer(rows).plan(options)[:products]).to eq([])
      products_kept = importer(rows).plan(options(include_product_pages: true))[:products]

      expect(products_kept.map { |p| p.slice(:key, :title, :origin, :source) })
        .to eq([{ key: "title:trail-boots", title: "Trail Boots", origin: "https://shop.example",
                  source: "history" }])
    end

    it "explains a permission error on any other browser's profile folder, and stops" do
      FileUtils.mkdir_p(@root)
      allow(Dir).to receive(:glob).and_raise(Errno::EPERM, "Operation not permitted")

      plan = described_class.new(stores: stores, products: products, known_cache: known_cache, prober: prober)
                            .plan(options)

      expect(plan).to include(error: "permission_denied")
      expect(plan[:message]).to include("chrome", "doesn't try any other way")
      expect(probed).to eq([])
    end

    it "explains a missing profile rather than raising" do
      plan = described_class.new(stores: stores, products: products, known_cache: known_cache, prober: prober)
                            .plan(options(root: File.join(@dir, "nope")))

      expect(plan).to include(error: "no_profile")
    end

    it "explains Safari's Full Disk Access prompt and stops — nothing read, nothing probed" do
      FileUtils.mkdir_p(@root)
      File.write(File.join(@root, "History.db"), "")
      allow(FileUtils).to receive(:cp).and_raise(Errno::EPERM, "Operation not permitted")

      plan = described_class.new(stores: stores, products: products, known_cache: known_cache, prober: prober)
                            .plan(options(browser: "safari"))

      expect(plan[:error]).to eq("full_disk_access_required")
      expect(plan[:message]).to include("Full Disk Access", "System Settings", "doesn't try any other way")
      expect(probed).to eq([])
    end
  end

  describe "#save" do
    it "writes kept domains as history/bookmark index entries" do
      ucp_origins << "https://shop.example"
      imp = importer([row("https://shop.example/products/knife", title: "Kitchen Knives"),
                      row("https://shop.example/", kind: "bookmark")])

      result = imp.save(imp.plan(options))

      entry = stores.find("https://shop.example")
      expect(result).to eq(stores: 1, products: 0)
      expect(entry).to include("sources" => %w[bookmark history], "capabilities" => ["catalog"],
                               "handoff_only" => false, "platform" => nil)
      expect(entry["categories"]).not_to be_empty
    end

    it "adds its labels to an existing entry without clobbering what another source found" do
      stores.upsert("https://shop.example", sources: ["shopify_catalog"], capabilities: %w[catalog cart checkout],
                                            last_verified: 1000)
      imp = importer([row("https://shop.example/")])

      imp.save(imp.plan(options))

      expect(stores.find("https://shop.example"))
        .to include("sources" => %w[shopify_catalog history], "capabilities" => %w[catalog cart checkout],
                    "last_verified" => 1000)
    end

    it "keeps a known-stores entry's own last_verified, since the import never probed it" do
      File.write(File.join(@dir, "known-stores.json"),
                 JSON.generate("https://known.example" => { "origin" => "https://known.example",
                                                            "capabilities" => ["catalog"], "last_verified" => 42 }))
      imp = importer([row("https://known.example/")])

      imp.save(imp.plan(options))

      expect(stores.find("https://known.example"))
        .to include("sources" => ["history"], "capabilities" => ["catalog"], "last_verified" => 42)
    end

    it "plan alone never writes anything" do
      ucp_origins << "https://shop.example"

      importer([row("https://shop.example/products/x", title: "X")]).plan(options(include_product_pages: true))

      expect(stores.all).to eq([])
      expect(products.all).to eq([])
    end

    it "writes product pages with personal source labels" do
      ucp_origins << "https://shop.example"
      imp = importer([row("https://shop.example/products/trail-boots", title: "Trail Boots", kind: "bookmark")])

      imp.save(imp.plan(options(include_product_pages: true)))

      expect(products.find("title:trail-boots")).to include("title" => "Trail Boots", "sources" => ["bookmark"])
    end
  end

  describe "what leaves the machine" do
    it "sends nothing but one GET /.well-known/ucp per unknown domain, through the real discovery path" do
      manifest = stub_request(:get, "https://shop.example/.well-known/ucp").to_return(status: 404)
      other = stub_request(:get, "https://other.example/.well-known/ucp").to_return(status: 404)
      real_prober = Portage::Cli::BrowserImport::Prober.new(cache: probe_cache, throttle: 0)
      fake_profile!
      rows = [row("https://shop.example/products/secret-thing?ref=private", title: "Private title", visits: 3),
              row("https://shop.example/account"), row("https://other.example/x")]
      reader = double("Reader", history: rows, bookmarks: [])

      described_class.new(stores: stores, products: products, known_cache: known_cache, prober: real_prober,
                          readers: ->(_f) { reader }).plan(options)

      expect(manifest).to have_been_requested.once
      expect(other).to have_been_requested.once
      expect(a_request(:any, /secret-thing|private|account/)).not_to have_been_made
    end
  end

  describe "which files are opened (never a credential, cookie or autofill store)" do
    it "opens exactly Chrome's History and Bookmarks, lists only the profile root, and nothing else" do
      ucp_origins << "https://shop.example"
      profile = chrome_profile(@root, visits: [{ url: "https://shop.example/products/boots", title: "Boots" }],
                                      bookmarks: chrome_bookmarks("Shops" => [["https://shop.example/", "Shop"]]))
      imp = described_class.new(stores: stores, products: products, known_cache: known_cache, prober: prober)

      plan = nil
      touched = paths_touched_under(@root) { plan = imp.plan(options) }

      expect(touched).to contain_exactly(File.join(profile, "History"), File.join(profile, "Bookmarks"),
                                         File.join(@root, "{Default,Profile *}"))
      expect(plan[:files_opened]).to eq([File.join(profile, "History"), File.join(profile, "Bookmarks")])
      expect(JSON.generate(plan)).not_to include(BrowserImportFixtures::SENTINEL)
      expect(plan[:kept].map { |e| e[:domain] }).to eq(["shop.example"])
    end

    it "opens exactly Firefox's places.sqlite, and none of logins.json/key4.db/cookies.sqlite/formhistory.sqlite" do
      profile = firefox_profile(@root, visits: [{ url: "https://shop.example/", title: "Shop" }],
                                       bookmarks: [[1, "Shop"]])
      imp = described_class.new(stores: stores, products: products, known_cache: known_cache, prober: prober)

      touched = paths_touched_under(@root) { imp.plan(options(browser: "firefox")) }

      expect(touched).to contain_exactly(File.join(profile, "places.sqlite"), File.join(@root, "Profiles", "*"))
    end
  end
end
