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
  end

  describe Portage::Cli::SearchBackends::Allowlist do
    it "merges PORTAGE_STORES and the yaml file, deduped" do
      allow(File).to receive(:readable?).with("/tmp/stores.yml").and_return(true)
      allow(YAML).to receive(:safe_load_file).and_return(["https://shop.example", "https://other.example"])

      backend = described_class.new(path: "/tmp/stores.yml", env: "https://shop.example,")

      expect(backend.search("anything")).to eq(["https://shop.example", "https://other.example"])
    end

    it "is unavailable when there is no file and no env" do
      allow(File).to receive(:readable?).and_return(false)

      expect(described_class.new(path: "/nope.yml", env: nil).available?).to be false
    end
  end
end
