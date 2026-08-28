require "spec_helper"

RSpec.describe Portage::Cli::Compare do
  let(:cache) { instance_double(Portage::Cli::ProbeCache, fetch: nil, record: true) }

  def backend(name, urls)
    double = Object.new
    allow(double).to receive_messages(name: name, available?: true, search: urls)
    double
  end

  def variant(sku: nil, barcode: nil)
    { "id" => "v1", "sku" => sku, "barcodes" => barcode ? [{ "type" => "upc", "value" => barcode }] : [] }
  end

  def product(id: "p1", title: "Wool Throw", price: 2000, sku: nil, barcode: nil)
    { "id" => id, "title" => title, "url" => "https://shop.example/#{id}",
      "price_range" => { "min" => { "amount" => price, "currency" => "USD" } },
      "variants" => [variant(sku: sku, barcode: barcode)] }
  end

  def origin_session(product: nil)
    instance_double(Portage::Ucp::Client::Session, get_product: product && { "product" => product })
  end

  def candidate_session(products: [])
    instance_double(Portage::Ucp::Client::Session, advertises?: true,
                                                   search_catalog: { "ucp" => 1, "products" => products })
  end

  # Dispatches Client.discover by origin so the origin resolution call and
  # the per-candidate probe calls (inherited from Find) can return different
  # sessions in the same test.
  def stub_discover(sessions_by_origin)
    allow(Portage::Ucp::Client).to receive(:discover) { |origin| sessions_by_origin[origin] }
  end

  def compare(origin_url: "https://origin.example", origin_product_id: "orig1", backends: [], **overrides)
    described_class.new(origin_url: origin_url, origin_product_id: origin_product_id,
                        find_options: { backends: backends, cache: cache, throttle: 0 }, **overrides)
  end

  it "reports the origin URL as unparseable instead of raising" do
    report = compare(origin_url: "not a url").call

    expect(report[:message]).to include("Not a store URL")
  end

  it "reports a non-UCP origin store instead of raising" do
    stub_discover("https://origin.example" => nil)

    report = compare.call

    expect(report[:message]).to include("doesn't speak UCP")
  end

  it "reports an origin product that isn't found instead of raising" do
    stub_discover("https://origin.example" => origin_session(product: nil))

    report = compare(origin_product_id: "missing").call

    expect(report[:message]).to include('Product "missing" not found')
  end

  it "excludes the origin store from ranked offers, matching on host not on the raw origin string" do
    origin = product(id: "orig1", sku: "WT-100")
    same_store_offer = product(id: "orig1-again", sku: "WT-100")
    stub_discover(
      "https://origin.example" => origin_session(product: origin),
      "http://origin.example" => candidate_session(products: [same_store_offer])
    )
    backends = [backend("duckduckgo", ["http://origin.example"])]

    report = compare(origin_url: "https://origin.example", backends: backends).call

    expect(report[:offers]).to be_empty
    expect(report[:message]).to include("1 excluded (origin store)")
  end

  it "treats a www variant as a different host, same as Find's own candidate dedupe" do
    origin = product(id: "orig1", sku: "WT-100")
    other_offer = product(id: "p-www", sku: "WT-100", price: 999)
    stub_discover(
      "https://origin.example" => origin_session(product: origin),
      "https://www.origin.example" => candidate_session(products: [other_offer])
    )
    backends = [backend("duckduckgo", ["https://www.origin.example"])]

    report = compare(origin_url: "https://origin.example", backends: backends).call

    expect(report[:offers]).not_to be_empty
    expect(report[:message]).not_to include("excluded (origin store)")
  end

  it "ranks a confirmed barcode match above a likely sku match above an unconfirmed match, regardless of price" do
    origin = product(id: "orig1", sku: "WT-100", barcode: "012345678905")
    confirmed = product(id: "p-confirmed", price: 3000, barcode: "012345678905")
    likely = product(id: "p-likely", price: 1500, sku: "wt-100")
    unconfirmed = product(id: "p-unconfirmed", price: 500)
    stub_discover(
      "https://origin.example" => origin_session(product: origin),
      "https://a.example" => candidate_session(products: [confirmed]),
      "https://b.example" => candidate_session(products: [likely]),
      "https://c.example" => candidate_session(products: [unconfirmed])
    )
    backends = [backend("duckduckgo", %w[https://a.example https://b.example https://c.example])]

    report = compare(origin_url: "https://origin.example", backends: backends).call

    expect(report[:offers].map { |o| o[:product_id] }).to eq(%w[p-confirmed p-likely p-unconfirmed])
    expect(report[:offers].map { |o| o[:match] }).to eq(%i[confirmed likely unconfirmed])
  end

  it "lets an explicit --id override the origin's own sku/barcodes" do
    origin = product(id: "orig1", sku: "WT-100")
    hit = product(id: "p-hit", sku: "OTHER-SKU", barcode: "999888777")
    stub_discover(
      "https://origin.example" => origin_session(product: origin),
      "https://a.example" => candidate_session(products: [hit])
    )
    backends = [backend("duckduckgo", ["https://a.example"])]

    report = compare(origin_url: "https://origin.example", backends: backends, identity: ["999888777"]).call

    expect(report[:offers].first[:match]).to eq(:likely)
  end

  it "truncates to --results after ranking, not before" do
    origin = product(id: "orig1")
    cheap = product(id: "p-cheap", price: 100)
    mid = product(id: "p-mid", price: 200)
    pricey = product(id: "p-pricey", price: 300)
    stub_discover(
      "https://origin.example" => origin_session(product: origin),
      "https://a.example" => candidate_session(products: [pricey]),
      "https://b.example" => candidate_session(products: [cheap]),
      "https://c.example" => candidate_session(products: [mid])
    )
    backends = [backend("duckduckgo", %w[https://a.example https://b.example https://c.example])]

    report = compare(origin_url: "https://origin.example", backends: backends, results: 2).call

    expect(report[:offers].map { |o| o[:product_id] }).to eq(%w[p-cheap p-mid])
    expect(report[:message]).to include("1 more not shown (--results 2)")
  end

  it "pins shown/truncated/excluded counts against one fixture where all three are non-zero and distinct" do
    origin = product(id: "orig1", sku: "WT-100")
    same_store = product(id: "orig1-again", sku: "WT-100")
    a = product(id: "p-a", price: 100)
    b = product(id: "p-b", price: 200)
    c = product(id: "p-c", price: 300)
    d = product(id: "p-d", price: 400)
    stub_discover(
      "https://origin.example" => origin_session(product: origin),
      "http://origin.example" => candidate_session(products: [same_store]),
      "https://a.example" => candidate_session(products: [a]),
      "https://b.example" => candidate_session(products: [b]),
      "https://c.example" => candidate_session(products: [c]),
      "https://d.example" => candidate_session(products: [d])
    )
    backends = [backend("duckduckgo",
                        %w[http://origin.example https://a.example https://b.example https://c.example
                           https://d.example])]

    report = compare(origin_url: "https://origin.example", backends: backends, results: 2).call

    expect(report[:offers].length).to eq(2)
    expect(report[:message]).to include("Found 2 offer(s)")
    expect(report[:message]).to include("2 more not shown (--results 2)")
    expect(report[:message]).to include("1 excluded (origin store)")
  end
end
