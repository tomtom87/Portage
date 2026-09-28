require "spec_helper"

RSpec.describe Portage::Cli::Index::Sources do
  it "lists every registered source, whether or not it runs by default" do
    expect(described_class.all.map(&:name)).to contain_exactly(
      "shopify_catalog", "stores_file", "browser", "wikidata", "webmcp_sweep"
    )
  end

  it "runs only the sources that need no opt-in by default" do
    expect(described_class.default.map(&:name)).to contain_exactly("shopify_catalog", "stores_file")
  end

  it "builds by name, dropping anything unknown" do
    built = described_class.by_name(%w[stores_file nope wikidata])

    expect(built.map(&:name)).to eq(%w[stores_file wikidata])
  end

  it "returns an empty array for an empty or nil name list" do
    expect(described_class.by_name(nil)).to eq([])
    expect(described_class.by_name([])).to eq([])
  end
end
