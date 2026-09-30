require "spec_helper"

RSpec.describe Portage::Cli::Find do
  let(:product) do
    { "id" => "p1", "title" => "Cold Brew", "url" => "https://shop.example/p1",
      "price_range" => { "min" => { "amount" => 2400, "currency" => "USD" } } }
  end
  let(:cache) { instance_double(Portage::Cli::ProbeCache, fetch: nil, record: true) }

  def backend(name, urls)
    double = Object.new
    allow(double).to receive_messages(name: name, available?: true, search: urls)
    double
  end

  def session(advertises: true, products: [])
    instance_double(Portage::Ucp::Client::Session, advertises?: advertises,
                                                   search_catalog: { "ucp" => 1, "products" => products })
  end

  # offer_sources defaults to [] here rather than OfferSources.default: a
  # live ShopifyCatalog would otherwise dial a real endpoint on every spec
  # in this file that doesn't care about it — see "merges offer-source
  # offers" below for the tests that do.
  def find(**overrides)
    described_class.new(query: "cold brew", cache: cache, throttle: 0, offer_sources: [], **overrides)
  end

  def offer_source(offers)
    double = Object.new
    allow(double).to receive(:offers).and_return(offers)
    double
  end

  it "gives every offer a short opaque offer_ref, distinct within a search" do
    allow(Portage::Ucp::Client).to receive(:discover)
      .and_return(session(products: [product, product.merge("id" => "p2")]))

    report = find(backends: [backend("duckduckgo", ["https://shop.example"])]).call

    refs = report[:offers].map { |o| o[:offer_ref] }
    expect(refs.length).to eq(2)
    expect(refs).to all(match(/\Aof_[0-9a-f]{6}\z/))
    expect(refs.uniq.length).to eq(2)
  end

  it "returns nothing without a query" do
    report = described_class.new(query: "  ", cache: cache, throttle: 0, backends: []).call

    expect(report[:offers]).to be_empty
    expect(report[:message]).to include("--query")
  end

  it "says which backends came up empty" do
    report = find(backends: [backend("duckduckgo", [])]).call

    expect(report[:message]).to include("duckduckgo")
  end

  it "nudges toward a real search backend when duckduckgo is the only one running" do
    report = find(backends: [backend("duckduckgo", [])]).call

    expect(report[:message]).to include("BRAVE_SEARCH_API_KEY", "GOOGLE_CSE_KEY", "portage doctor")
  end

  it "skips the nudge once a keyed backend is also running, empty or not" do
    report = find(backends: [backend("duckduckgo", []), backend("brave", [])]).call

    expect(report[:message]).not_to include("BRAVE_SEARCH_API_KEY")
  end

  it "tells you to configure a backend when none are available" do
    report = find(backends: []).call

    expect(report[:message]).to include("BRAVE_SEARCH_API_KEY")
  end

  it "collapses deep links onto origins and dedupes across backends" do
    backends = [backend("allowlist", ["https://shop.example/products/a"]),
                backend("duckduckgo", ["https://shop.example/products/b", "https://other.example"])]
    allow(Portage::Ucp::Client).to receive(:discover).and_return(session)

    report = find(backends: backends).call

    expect(report[:candidates].map { |c| c[:origin] }).to eq(["https://shop.example", "https://other.example"])
    expect(report[:candidates].first[:source]).to eq("allowlist")
  end

  it "probes a host once, preferring https when both schemes come back" do
    allow(Portage::Ucp::Client).to receive(:discover).and_return(session)

    report = find(backends: [backend("duckduckgo", ["http://www.shop.example", "https://www.shop.example"])]).call

    expect(report[:candidates].map { |c| c[:origin] }).to eq(["https://www.shop.example"])
  end

  it "keeps an http-only host as it was given" do
    allow(Portage::Ucp::Client).to receive(:discover).and_return(session)

    report = find(backends: [backend("duckduckgo", ["http://shop.example", "http://shop.example/x"])]).call

    expect(report[:candidates].map { |c| c[:origin] }).to eq(["http://shop.example"])
  end

  it "ignores URLs that aren't http, whatever a backend hands back" do
    report = find(backends: [backend("duckduckgo", ["mailto:sales@shop.example", "ftp://shop.example"])]).call

    expect(report[:candidates]).to be_empty
  end

  it "caps probes at MAX_PROBES even when the caller asks for more" do
    urls = Array.new(described_class::MAX_PROBES + 3) { |i| "https://shop#{i}.example" }
    allow(Portage::Ucp::Client).to receive(:discover).and_return(session)

    report = find(backends: [backend("duckduckgo", urls)], limit: 50).call

    expect(report[:candidates].length).to eq(described_class::MAX_PROBES)
  end

  it "waits between probes, but not before the first one" do
    finder = find(backends: [backend("duckduckgo", %w[https://a.example https://b.example])], throttle: 0.1)
    allow(finder).to receive(:sleep)
    allow(Portage::Ucp::Client).to receive(:discover).and_return(session)

    finder.call

    expect(finder).to have_received(:sleep).with(0.1).once
  end

  it "records a live store as a hit" do
    allow(Portage::Ucp::Client).to receive(:discover).and_return(session)

    find(backends: [backend("duckduckgo", ["https://shop.example"])]).call

    expect(cache).to have_received(:record).with("https://shop.example", true)
  end

  it "drops candidates that don't answer the manifest probe" do
    allow(Portage::Ucp::Client).to receive(:discover)
      .and_raise(Portage::Ucp::Client::DiscoveryError.new("nope"))

    report = find(backends: [backend("duckduckgo", ["https://shop.example"])]).call

    expect(report[:stores]).to be_empty
    expect(report[:message]).to include("none of them speak UCP")
    expect(cache).to have_received(:record).with("https://shop.example", false)
  end

  it "skips re-probing an origin cached as a miss" do
    allow(cache).to receive(:fetch).with("https://shop.example").and_return(false)
    allow(Portage::Ucp::Client).to receive(:discover)

    find(backends: [backend("duckduckgo", ["https://shop.example"])]).call

    expect(Portage::Ucp::Client).not_to have_received(:discover)
  end

  it "builds offers from the wire shape's price_range" do
    allow(Portage::Ucp::Client).to receive(:discover).and_return(session(products: [product]))

    report = find(backends: [backend("duckduckgo", ["https://shop.example"])]).call

    expect(report[:offers].first).to include(store: "https://shop.example", product_id: "p1",
                                             title: "Cold Brew", amount: 2400, currency: "USD", checkout: true)
  end

  describe "product field" do
    let(:full) do
      product.merge("handle" => "cold-brew", "description" => { "plain" => "Smooth." },
                    "media" => [{ "type" => "image", "url" => "https://cdn.example/1.jpg" }],
                    "options" => [{ "name" => "Size", "values" => [{ "label" => "Large" }] }],
                    "variants" => [{ "id" => "v1", "title" => "Large",
                                     "price" => { "amount" => 2400, "currency" => "USD" } }])
    end

    it "carries the store's product wire hash as served, next to the flat fields" do
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session(products: [full]))

      offer = find(backends: [backend("duckduckgo", ["https://shop.example"])]).call[:offers].first

      expect(offer[:product]).to eq(full)
      expect(offer).to include(store: "https://shop.example", product_id: "p1", title: "Cold Brew",
                               amount: 2400, currency: "USD", url: "https://shop.example/p1", checkout: true)
    end

    it "keeps only the first image" do
      two = full.merge("media" => [{ "type" => "image", "url" => "a" }, { "type" => "image", "url" => "b" }])
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session(products: [two]))

      offer = find(backends: [backend("duckduckgo", ["https://shop.example"])]).call[:offers].first

      expect(offer[:product]["media"]).to eq([{ "type" => "image", "url" => "a" }])
    end

    it "does not persist the product into history" do
      offer = { offer_ref: "of_1", store: "https://s.example", product_id: "p", title: "T", amount: 1, currency: "USD",
                url: "https://s.example/p", checkout: true, product: full }

      saved = Portage::Cli::History.new.record_search(query: "q", offer_count: 1, message: nil, offers: [offer])

      expect(saved["offers"].first).not_to have_key("product")
    end
  end

  it "unwraps search_catalog's wire envelope instead of treating it as the product list" do
    allow(Portage::Ucp::Client).to receive(:discover).and_return(session(products: [product]))

    report = find(backends: [backend("duckduckgo", ["https://shop.example"])]).call

    expect(report[:offers].length).to eq(1)
    expect(report[:offers].first[:product_id]).to eq("p1")
  end

  it "filters out offers above --max-price" do
    allow(Portage::Ucp::Client).to receive(:discover).and_return(session(products: [product]))

    report = find(backends: [backend("duckduckgo", ["https://shop.example"])], max_price: 1000).call

    expect(report[:offers]).to be_empty
    expect(report[:message]).to include("none stock")
  end

  it "reads a bare integer price as minor units with no currency" do
    bare = { "id" => "p4", "title" => "Cold Brew", "price" => 500 }
    allow(Portage::Ucp::Client).to receive(:discover).and_return(session(products: [bare]))

    report = find(backends: [backend("duckduckgo", ["https://shop.example"])]).call

    expect(report[:offers].first).to include(amount: 500, currency: nil)
  end

  it "keeps an unpriced offer under --max-price rather than assuming it's too dear" do
    unpriced = { "id" => "p3", "title" => "Cold Brew" }
    allow(Portage::Ucp::Client).to receive(:discover).and_return(session(products: [unpriced]))

    report = find(backends: [backend("duckduckgo", ["https://shop.example"])], max_price: 1).call

    expect(report[:offers].map { |o| o[:product_id] }).to eq(["p3"])
  end

  it "ranks buyable stores above browse-only ones, then by price" do
    cheap = product.merge("id" => "p2", "price_range" => { "min" => { "amount" => 100, "currency" => "USD" } })
    browse_only = session(advertises: false, products: [cheap])
    allow(Portage::Ucp::Client).to receive(:discover).with("https://browse.example", headers: Portage::Cli::UserAgent.headers).and_return(browse_only)
    allow(Portage::Ucp::Client).to receive(:discover).with("https://shop.example", headers: Portage::Cli::UserAgent.headers)
                                                     .and_return(session(products: [product]))

    report = find(backends: [backend("duckduckgo", ["https://browse.example", "https://shop.example"])]).call

    expect(report[:offers].map { |o| o[:product_id] }).to eq(%w[p1 p2])
  end

  it "keeps searching when one store's catalog call blows up" do
    broken = instance_double(Portage::Ucp::Client::Session, advertises?: true)
    allow(broken).to receive(:search_catalog).and_raise(StandardError)
    allow(Portage::Ucp::Client).to receive(:discover).with("https://broken.example", headers: Portage::Cli::UserAgent.headers).and_return(broken)
    allow(Portage::Ucp::Client).to receive(:discover).with("https://shop.example", headers: Portage::Cli::UserAgent.headers)
                                                     .and_return(session(products: [product]))

    report = find(backends: [backend("duckduckgo", ["https://broken.example", "https://shop.example"])]).call

    expect(report[:offers].map { |o| o[:store] }).to eq(["https://shop.example"])
  end

  it "survives a backend that raises" do
    exploding = backend("duckduckgo", [])
    allow(exploding).to receive(:search).and_raise(StandardError)

    expect { find(backends: [exploding]).call }.not_to raise_error
  end

  describe "offer sources" do
    let(:catalog_offer) do
      { store: "https://catalog-merchant.example", source: "shopify_catalog", checkout: nil,
        product_id: "gid://shopify/ProductVariant/9", title: "Catalog Cold Brew", amount: 1500,
        currency: "USD", url: "https://catalog-merchant.example/products/x" }
    end

    it "merges an offer source's offers with probed-store offers, with no probe of its own" do
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session(products: [product]))

      report = find(backends: [backend("duckduckgo", ["https://shop.example"])],
                    offer_sources: [offer_source([catalog_offer])]).call

      expect(report[:offers].map { |o| o[:product_id] }).to contain_exactly("p1", "gid://shopify/ProductVariant/9")
      expect(report[:candidates].map { |c| c[:origin] }).to eq(["https://shop.example"])
    end

    it "ranks a merged offer source offer against probed offers by buyable-then-price, same as any other offer" do
      cheaper_unbuyable = catalog_offer.merge(amount: 100)
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session(products: [product]))

      report = find(backends: [backend("duckduckgo", ["https://shop.example"])],
                    offer_sources: [offer_source([cheaper_unbuyable])]).call

      expect(report[:offers].first[:product_id]).to eq("p1")
      expect(report[:offers].last[:product_id]).to eq("gid://shopify/ProductVariant/9")
    end

    it "filters an offer source's offers above --max-price too, keeping unpriced ones" do
      unpriced = catalog_offer.merge(product_id: "unpriced", amount: nil, currency: nil)

      report = find(backends: [], max_price: 1000, offer_sources: [offer_source([catalog_offer, unpriced])]).call

      expect(report[:offers].map { |o| o[:product_id] }).to eq(["unpriced"])
    end

    it "still reports offers when no search backend found any candidates" do
      report = find(backends: [], offer_sources: [offer_source([catalog_offer])]).call

      expect(report[:candidates]).to be_empty
      expect(report[:offers]).to match([include(catalog_offer)])
      expect(report[:message]).to eq("Found 1 offer(s) across 1 store(s).")
    end

    it "reports no candidates when both backends and offer sources come back empty" do
      report = find(backends: [], offer_sources: [offer_source([])]).call

      expect(report[:offers]).to be_empty
      expect(report[:message]).to include("BRAVE_SEARCH_API_KEY")
    end
  end

  # Integration for Phase 2a's category routing (docs/plans/buy-skill-and-
  # local-browser.md): a real Allowlist, reading a real (tmpdir) stores.yml,
  # feeding Find exactly the way SearchBackends.default does — the unit
  # coverage for the routing algorithm itself lives in search_backends_spec.
  describe "category routing through a real Allowlist" do
    around do |example|
      Dir.mktmpdir do |dir|
        @stores_path = File.join(dir, "stores.yml")
        example.run
      end
    end

    def allowlist_backend(entries)
      File.write(@stores_path, entries.to_yaml)
      Portage::Cli::SearchBackends::Allowlist.new(path: @stores_path, env: nil)
    end

    it "loads a bare URL list" do
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session)
      allow(Portage::Cli::Classifier).to receive(:categories_for).and_return([])

      bare = allowlist_backend(["https://a.example", "https://b.example"])

      report = find(backends: [bare]).call

      expect(report[:candidates].map { |c| c[:origin] }).to contain_exactly("https://a.example", "https://b.example")
    end

    it "loads a tagged {url:, categories:} list" do
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session)
      allow(Portage::Cli::Classifier).to receive(:categories_for).and_return(["635"])

      tagged = allowlist_backend([{ "url" => "https://a.example", "categories" => ["635"] },
                                  { "url" => "https://b.example", "categories" => ["635"] }])

      report = find(backends: [tagged]).call

      expect(report[:candidates].map { |c| c[:origin] }).to contain_exactly("https://a.example", "https://b.example")
    end

    it "never probes more than 12 stores.yml entries for one query, even across several matching categories" do
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session)
      allow(Portage::Cli::Classifier).to receive(:categories_for).and_return(%w[1 2 3 4 5])

      entries = (1..20).map { |i| { "url" => "https://shop#{i}.example", "categories" => [((i % 5) + 1).to_s] } }

      report = find(backends: [allowlist_backend(entries)]).call

      expect(report[:candidates].length).to eq(described_class::MAX_PROBES)
    end

    it "never crowds out an untagged, unnamed store's slot once a tagged category match exists" do
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session)
      allow(Portage::Cli::Classifier).to receive(:categories_for).and_return(["635"])

      entries = (1..10).map { |i| "https://random-#{i}.example" } +
                [{ "url" => "https://sofa.example", "categories" => ["635"] }]

      report = find(backends: [allowlist_backend(entries)]).call

      expect(report[:candidates].map { |c| c[:origin] }).to eq(["https://sofa.example"])
    end
  end

  describe "Tier C: hand-off-only hosts (docs/plans/buy-skill-and-local-browser.md Phase 5)" do
    # HandoffOnly.new (Find's default) reads Config.load, which
    # spec_helper.rb already redirects to a per-example tmpdir — no double
    # needed, and this exercises the real host+subdomain matching.
    before { Portage::Cli::Config.load.set("handoff_only_hosts", ["amazon.co.uk"]) }

    it "never probes a candidate on the hand-off-only list, even when a backend surfaces it" do
      expect(Portage::Ucp::Client).not_to receive(:discover)

      report = find(backends: [backend("duckduckgo", ["https://www.amazon.co.uk/s?k=kettle"])]).call

      expect(report[:candidates].first[:handoff_only]).to be true
    end

    it "never probes a search-engine URL pointing at a hand-off-only origin" do
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session)

      find(backends: [backend("duckduckgo", ["https://www.amazon.co.uk/s?k=kettle", "https://shop.example"])]).call

      expect(Portage::Ucp::Client).to have_received(:discover).with("https://shop.example", anything)
      expect(Portage::Ucp::Client).not_to have_received(:discover).with("https://www.amazon.co.uk", anything)
    end

    it "still lists it as a candidate, marked handoff_only: true, never as a probed store" do
      report = find(backends: [backend("duckduckgo", ["https://www.amazon.co.uk/s?k=kettle"])]).call

      expect(report[:stores]).to eq([{ origin: "https://www.amazon.co.uk", source: "duckduckgo", checkout: false,
                                       handoff_only: true }])
    end

    it "marks a probed, non-hand-off-only store handoff_only: false" do
      allow(Portage::Ucp::Client).to receive(:discover).and_return(session)

      report = find(backends: [backend("duckduckgo", ["https://shop.example"])]).call

      expect(report[:stores].first[:handoff_only]).to be false
    end
  end
end
