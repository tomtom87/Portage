require "spec_helper"

RSpec.describe Portage::Cli::Index::Sources::StoresFile do
  let(:allowlist) { instance_double(Portage::Cli::SearchBackends::Allowlist) }
  let(:source) { described_class.new(allowlist: allowlist) }

  it "turns every stores.yml entry into a store-only sighting (no product identity)" do
    allow(allowlist).to receive(:stores).and_return([{ url: "https://shop.example", categories: [] }])

    expect(source.candidates).to eq([{ origin: "https://shop.example", url: nil, title: nil, brand: nil,
                                       gtin: nil }])
  end

  it "drops an entry whose URL doesn't parse as http(s)" do
    allow(allowlist).to receive(:stores).and_return([{ url: "not a url", categories: [] }])

    expect(source.candidates).to eq([])
  end

  it "reports the same path stores.yml itself uses" do
    allow(allowlist).to receive(:stores).and_return([])

    expect(source.source_path).to eq(Portage::Cli::SearchBackends::Allowlist::PATH)
    expect(source.name).to eq("stores_file")
  end
end
