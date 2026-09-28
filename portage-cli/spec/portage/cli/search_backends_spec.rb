require "spec_helper"

RSpec.describe Portage::Cli::SearchBackends do
  describe ".store_candidate?" do
    it "keeps ordinary shop URLs" do
      expect(described_class.store_candidate?("https://shop.example/products/x")).to be true
    end

    it "rejects reference sites and search engines, subdomains included" do
      expect(described_class.store_candidate?("https://en.wikipedia.org/wiki/Snowboard")).to be false
      expect(described_class.store_candidate?("https://duckduckgo.com/c/Snowboarding")).to be false
    end

    it "rejects unparseable input rather than probing it" do
      expect(described_class.store_candidate?("not a url")).to be false
    end
  end

  describe ".default" do
    it "only includes backends whose credentials are present" do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("BRAVE_SEARCH_API_KEY", nil).and_return(nil)
      allow(ENV).to receive(:fetch).with("GOOGLE_CSE_KEY", nil).and_return(nil)
      allow(ENV).to receive(:fetch).with("GOOGLE_CSE_CX", nil).and_return(nil)
      allow(ENV).to receive(:fetch).with("PORTAGE_STORES", nil).and_return(nil)
      allow(File).to receive(:readable?).and_return(false)

      expect(described_class.default.map(&:name)).to eq(%w[duckduckgo])
    end
  end

  describe Portage::Cli::SearchBackends::DuckDuckGo do
    let(:body) do
      {
        "Results" => [{ "FirstURL" => "https://www.burton.com" }],
        "RelatedTopics" => [
          { "FirstURL" => "https://duckduckgo.com/c/Snowboarding_companies" },
          { "Topics" => [{ "FirstURL" => "https://shop.example/gear" }] }
        ],
        "AbstractURL" => "https://en.wikipedia.org/wiki/Burton_Snowboards"
      }.to_json
    end

    it "returns official-site and nested related URLs, dropping non-stores" do
      stub_request(:get, /api\.duckduckgo\.com/).to_return(body: body, status: 200)

      expect(described_class.new.search("burton snowboards"))
        .to eq(["https://www.burton.com", "https://shop.example/gear"])
    end

    it "returns nothing rather than raising when the API is unreachable" do
      stub_request(:get, /api\.duckduckgo\.com/).to_timeout

      expect(described_class.new.search("snowboard")).to eq([])
    end

    it "is always available, since it needs no key" do
      expect(described_class.new.available?).to be true
    end
  end

  describe Portage::Cli::SearchBackends::Brave do
    it "reads results from the documented JSON shape" do
      stub_request(:get, /api\.search\.brave\.com/)
        .with(headers: { "X-Subscription-Token" => "key_1" })
        .to_return(body: { "web" => { "results" => [{ "url" => "https://shop.example" }] } }.to_json, status: 200)

      expect(described_class.new(api_key: "key_1").search("snowboard")).to eq(["https://shop.example"])
    end

    it "drops non-store results, the same filter DuckDuckGo gets" do
      stub_request(:get, /api\.search\.brave\.com/).to_return(
        body: { "web" => { "results" => [{ "url" => "https://en.wikipedia.org/wiki/Snowboard" },
                                         { "url" => "https://shop.example" }] } }.to_json,
        status: 200
      )

      expect(described_class.new(api_key: "key_1").search("snowboard")).to eq(["https://shop.example"])
    end

    it "returns nothing rather than raising when the API rate-limits the run" do
      stub_request(:get, /api\.search\.brave\.com/).to_return(
        status: 429, body: { "type" => "ErrorResponse", "error" => { "code" => "RATE_LIMITED" } }.to_json
      )

      expect(described_class.new(api_key: "key_1").search("snowboard")).to eq([])
    end

    it "is unavailable without a key" do
      expect(described_class.new(api_key: nil).available?).to be false
    end
  end

  describe Portage::Cli::SearchBackends::GoogleCse do
    it "needs both the key and the engine id" do
      expect(described_class.new(api_key: "k", cx: nil).available?).to be false
      expect(described_class.new(api_key: "k", cx: "cx").available?).to be true
    end

    it "reads links out of items" do
      stub_request(:get, /customsearch/).to_return(
        body: { "items" => [{ "link" => "https://shop.example/x" }] }.to_json, status: 200
      )

      expect(described_class.new(api_key: "k", cx: "cx").search("snowboard")).to eq(["https://shop.example/x"])
    end

    it "drops non-store links" do
      stub_request(:get, /customsearch/).to_return(
        body: { "items" => [{ "link" => "https://en.wikipedia.org/wiki/Snowboard" },
                            { "link" => "https://shop.example/x" }] }.to_json,
        status: 200
      )

      expect(described_class.new(api_key: "k", cx: "cx").search("snowboard")).to eq(["https://shop.example/x"])
    end

    it "never asks for more than the ten results the API will return" do
      stub = stub_request(:get, /customsearch/).with(query: hash_including("num" => "10"))
                                               .to_return(body: { "items" => [] }.to_json, status: 200)

      described_class.new(api_key: "k", cx: "cx").search("snowboard", limit: 25)

      expect(stub).to have_been_requested
    end
  end

  describe Portage::Cli::SearchBackends::Allowlist do
    it "merges PORTAGE_STORES and the yaml file, deduped" do
      allow(File).to receive(:readable?).and_return(false)
      allow(File).to receive(:readable?).with("/tmp/stores.yml").and_return(true)
      allow(YAML).to receive(:safe_load_file).with("/tmp/stores.yml")
                                             .and_return(["https://shop.example", "https://other.example"])

      backend = described_class.new(path: "/tmp/stores.yml", env: "https://shop.example,")

      expect(backend.search("anything")).to eq(["https://shop.example", "https://other.example"])
    end

    it "keeps the env entries when the yaml file is malformed" do
      allow(File).to receive(:readable?).and_return(false)
      allow(File).to receive(:readable?).with("/tmp/stores.yml").and_return(true)
      allow(YAML).to receive(:safe_load_file).with("/tmp/stores.yml")
                                             .and_raise(Psych::SyntaxError.new("stores.yml", 1, 1, 0, nil, nil))

      backend = described_class.new(path: "/tmp/stores.yml", env: "https://shop.example")

      expect(backend.search("anything")).to eq(["https://shop.example"])
    end

    it "honours the caller's limit" do
      allow(File).to receive(:readable?).and_return(false)

      backend = described_class.new(path: "/nope.yml", env: "https://a.example,https://b.example")

      expect(backend.search("anything", limit: 1)).to eq(["https://a.example"])
    end

    it "is unavailable when there is no file and no env" do
      allow(File).to receive(:readable?).and_return(false)

      expect(described_class.new(path: "/nope.yml", env: nil).available?).to be false
    end

    describe "category routing (docs/plans/buy-skill-and-local-browser.md Phase 2a)" do
      def stub_stores(entries)
        allow(File).to receive(:readable?).and_return(false)
        allow(File).to receive(:readable?).with("/tmp/stores.yml").and_return(true)
        allow(YAML).to receive(:safe_load_file).with("/tmp/stores.yml").and_return(entries)
      end

      def backend
        described_class.new(path: "/tmp/stores.yml", env: nil)
      end

      it "parses a bare URL string entry" do
        stub_stores(["https://plain.example"])
        allow(Portage::Cli::Classifier).to receive(:categories_for).and_return([])

        expect(backend.search("anything")).to eq(["https://plain.example"])
      end

      it "parses a {url:, categories:} entry" do
        stub_stores([{ "url" => "https://tagged.example", "categories" => ["1"] }])
        allow(Portage::Cli::Classifier).to receive(:categories_for).and_return(["1"])

        expect(backend.search("anything")).to eq(["https://tagged.example"])
      end

      it "takes at most 3 tagged stores per matching category, most-matched category first" do
        entries = (1..5).map { |i| { "url" => "https://cat1-#{i}.example", "categories" => ["1"] } } +
                  (1..2).map { |i| { "url" => "https://cat2-#{i}.example", "categories" => ["2"] } }
        stub_stores(entries)
        allow(Portage::Cli::Classifier).to receive(:categories_for).with("sofa").and_return(%w[1 2])

        expect(backend.search("sofa", limit: 12))
          .to eq(%w[cat1-1 cat1-2 cat1-3 cat2-1 cat2-2].map { |h| "https://#{h}.example" })
      end

      it "never returns more than 12 in total, even across several matching categories" do
        entries = (1..15).map { |i| { "url" => "https://s#{i}.example", "categories" => [(i % 5).to_s] } }
        stub_stores(entries)
        allow(Portage::Cli::Classifier).to receive(:categories_for).and_return(%w[0 1 2 3 4])

        expect(backend.search("anything", limit: 12).length).to eq(12)
      end

      it "keeps an untagged store out unless the query names it" do
        stub_stores([
                      { "url" => "https://sofa.example", "categories" => ["1"] },
                      "https://unrelated-shop.example"
                    ])
        allow(Portage::Cli::Classifier).to receive(:categories_for).and_return(["1"])

        expect(backend.search("buy a sofa")).to eq(["https://sofa.example"])
        expect(backend.search("buy from unrelated-shop"))
          .to contain_exactly("https://sofa.example", "https://unrelated-shop.example")
      end

      it "falls back to named entries plus untagged entries — never a tagged-but-unmatched one — " \
         "when no tagged store matches the query's categories" do
        stub_stores([
                      { "url" => "https://sofa.example", "categories" => ["1"] },
                      "https://unrelated-shop.example"
                    ])
        allow(Portage::Cli::Classifier).to receive(:categories_for).and_return(["999"])

        expect(backend.search("anything")).to eq(["https://unrelated-shop.example"])
      end

      it "still includes a tagged-but-unmatched store in the fallback when the query names it" do
        stub_stores([
                      { "url" => "https://sofa.example", "categories" => ["1"] },
                      "https://unrelated-shop.example"
                    ])
        allow(Portage::Cli::Classifier).to receive(:categories_for).and_return(["999"])

        expect(backend.search("buy from sofa"))
          .to contain_exactly("https://sofa.example", "https://unrelated-shop.example")
      end

      it "never falls back to every store once a tagged match exists — the crowding fix" do
        untagged = (1..20).map { |i| "https://random-#{i}.example" }
        stub_stores(untagged + [{ "url" => "https://sofa.example", "categories" => ["1"] }])
        allow(Portage::Cli::Classifier).to receive(:categories_for).and_return(["1"])

        expect(backend.search("buy a sofa", limit: 12)).to eq(["https://sofa.example"])
      end

      it "puts a named store first, ahead of category matches, even when that fills the total cap" do
        category_matches = %w[1 2 3 4].flat_map do |cat|
          (1..3).map { |i| { "url" => "https://cat#{cat}-#{i}.example", "categories" => [cat] } }
        end
        stub_stores(category_matches + [{ "url" => "https://named.example", "categories" => ["5"] }])
        allow(Portage::Cli::Classifier).to receive(:categories_for).and_return(%w[1 2 3 4])

        result = backend.search("buy from named", limit: 12)

        expect(result.first).to eq("https://named.example")
        expect(result.length).to eq(12)
      end
    end
  end
end
