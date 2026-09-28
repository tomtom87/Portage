require "spec_helper"

RSpec.describe Portage::Cli::Index::Sources::Wikidata do
  let(:body) do
    {
      "results" => {
        "bindings" => [
          { "item" => { "value" => "http://www.wikidata.org/entity/Q1" },
            "itemLabel" => { "value" => "Venchi" }, "website" => { "value" => "https://venchi.com" } },
          { "item" => { "value" => "http://www.wikidata.org/entity/Q2" },
            "itemLabel" => { "value" => "No Site" } }
        ]
      }
    }.to_json
  end

  it "turns a SPARQL row with a website into a sighting" do
    stub_request(:get, %r{query\.wikidata\.org/sparql}).to_return(body: body, status: 200)

    expect(described_class.new.candidates).to eq([{ origin: "https://venchi.com", url: "https://venchi.com",
                                                    title: nil, brand: "Venchi", gtin: nil }])
  end

  it "returns nothing rather than raising when the endpoint is unreachable" do
    stub_request(:get, %r{query\.wikidata\.org/sparql}).to_timeout

    expect(described_class.new.candidates).to eq([])
  end

  it "returns nothing on a non-200" do
    stub_request(:get, %r{query\.wikidata\.org/sparql}).to_return(status: 500)

    expect(described_class.new.candidates).to eq([])
  end

  it "is off by default (not in Sources.default), and named for opt-in" do
    expect(Portage::Cli::Index::Sources::DEFAULT_NAMES).not_to include("wikidata")
    expect(described_class.new.name).to eq("wikidata")
  end
end
