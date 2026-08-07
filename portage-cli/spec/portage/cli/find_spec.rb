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
    instance_double(Portage::Ucp::Client::Session, advertises?: advertises, search_catalog: products)
  end

  def find(**overrides)
    described_class.new(query: "cold brew", cache: cache, throttle: 0, **overrides)
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

  it "reads the price off a Product struct over the loopback transport" do
    struct = Portage::Ucp::Product.new(id: "p1", title: "Cold Brew", description: nil,
                                       price: Portage::Ucp::Money.new(amount_minor: 999, currency: "GBP"),
                                       available: true, variants: [], url: nil)
    allow(Portage::Ucp::Client).to receive(:discover).and_return(session(products: [struct]))

    report = find(backends: [backend("duckduckgo", ["https://shop.example"])]).call

    expect(report[:offers].first).to include(amount: 999, currency: "GBP")
  end

  it "filters out offers above --max-price" do
    allow(Portage::Ucp::Client).to receive(:discover).and_return(session(products: [product]))

    report = find(backends: [backend("duckduckgo", ["https://shop.example"])], max_price: 1000).call

    expect(report[:offers]).to be_empty
    expect(report[:message]).to include("none stock")
  end

  it "ranks buyable stores above browse-only ones, then by price" do
    cheap = product.merge("id" => "p2", "price_range" => { "min" => { "amount" => 100, "currency" => "USD" } })
    browse_only = session(advertises: false, products: [cheap])
    allow(Portage::Ucp::Client).to receive(:discover).with("https://browse.example").and_return(browse_only)
    allow(Portage::Ucp::Client).to receive(:discover).with("https://shop.example")
                                                     .and_return(session(products: [product]))

    report = find(backends: [backend("duckduckgo", ["https://browse.example", "https://shop.example"])]).call

    expect(report[:offers].map { |o| o[:product_id] }).to eq(%w[p1 p2])
  end

  it "keeps searching when one store's catalog call blows up" do
    broken = instance_double(Portage::Ucp::Client::Session, advertises?: true)
    allow(broken).to receive(:search_catalog).and_raise(StandardError)
    allow(Portage::Ucp::Client).to receive(:discover).with("https://broken.example").and_return(broken)
    allow(Portage::Ucp::Client).to receive(:discover).with("https://shop.example")
                                                     .and_return(session(products: [product]))

    report = find(backends: [backend("duckduckgo", ["https://broken.example", "https://shop.example"])]).call

    expect(report[:offers].map { |o| o[:store] }).to eq(["https://shop.example"])
  end

  it "survives a backend that raises" do
    exploding = backend("duckduckgo", [])
    allow(exploding).to receive(:search).and_raise(StandardError)

    expect { find(backends: [exploding]).call }.not_to raise_error
  end
end
