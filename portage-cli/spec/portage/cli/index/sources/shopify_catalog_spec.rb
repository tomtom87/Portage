require "spec_helper"

RSpec.describe Portage::Cli::Index::Sources::ShopifyCatalog do
  let(:catalog) { instance_double(Portage::Cli::OfferSources::ShopifyCatalog) }
  let(:source) { described_class.new(catalog: catalog) }

  let(:offer) do
    { store: "https://lemsshoes.com", source: "shopify_catalog", checkout: nil,
      product_id: "gid://shopify/ProductVariant/9", title: "Trail Boots", amount: 12_000, currency: "GBP",
      url: "https://lemsshoes.com/products/x" }
  end

  it "runs one query per top-level taxonomy node by default" do
    allow(catalog).to receive(:offers).and_return([])

    source.candidates

    expect(catalog).to have_received(:offers).with("animals", limit: described_class::PER_QUERY_LIMIT, context: {})
    expect(catalog).to have_received(:offers).with("apparel", limit: described_class::PER_QUERY_LIMIT, context: {})
  end

  it "runs exactly the queries given, not the taxonomy default" do
    allow(catalog).to receive(:offers).and_return([])

    source.candidates(queries: ["hiking boots"])

    expect(catalog).to have_received(:offers).once.with("hiking boots", limit: anything, context: anything)
  end

  it "turns an offer into a store+product sighting, dropping price/checkout fields" do
    allow(catalog).to receive(:offers).and_return([offer])

    candidates = source.candidates(queries: ["boots"])

    expect(candidates).to eq([{ origin: "https://lemsshoes.com", url: "https://lemsshoes.com/products/x",
                                title: "Trail Boots", brand: nil, gtin: nil }])
  end

  it "swallows a query that raises rather than failing the whole build" do
    allow(catalog).to receive(:offers).and_raise(StandardError, "boom")

    expect(source.candidates(queries: ["boots"])).to eq([])
  end

  it "names itself and its endpoint" do
    expect(source.name).to eq("shopify_catalog")
    expect(source.source_path).to be_nil
    expect(source.description).to be_a(String)
  end
end
