require "spec_helper"

RSpec.describe Portage::Cli::HandoffOnly do
  around { |example| Dir.mktmpdir { |dir| @config_path = File.join(dir, "config.json") and example.run } }

  def config(data = {})
    path = @config_path
    File.write(path, JSON.generate(data)) unless data.empty?
    Portage::Cli::Config.load(path: path)
  end

  describe "#hosts" do
    it "defaults to every Amazon marketplace when the key is absent" do
      handoff_only = described_class.new(config: config)

      expect(handoff_only.hosts).to eq(described_class::DEFAULT_HOSTS)
      expect(handoff_only.hosts).to include("amazon.com", "amazon.co.uk", "amazon.co.jp")
    end

    it "is entirely replaced by the user's own list, Amazon included" do
      handoff_only = described_class.new(config: config("handoff_only_hosts" => ["shop.example"]))

      expect(handoff_only.hosts).to eq(["shop.example"])
      expect(handoff_only.hosts).not_to include("amazon.com")
    end

    it "lets the user configure an empty list" do
      handoff_only = described_class.new(config: config("handoff_only_hosts" => []))

      expect(handoff_only.hosts).to eq([])
    end

    it "normalizes a \"www.\" entry to the bare host" do
      handoff_only = described_class.new(config: config("handoff_only_hosts" => ["www.shop.example"]))

      expect(handoff_only.hosts).to eq(["shop.example"])
    end

    it "normalizes a full URL entry (scheme, www., path and query) to the bare host" do
      handoff_only = described_class.new(config: config("handoff_only_hosts" =>
        ["https://www.shop.example/s?k=x"]))

      expect(handoff_only.hosts).to eq(["shop.example"])
    end

    it "normalizes a host-with-path entry (no scheme) to the bare host" do
      handoff_only = described_class.new(config: config("handoff_only_hosts" => ["shop.example/some/path"]))

      expect(handoff_only.hosts).to eq(["shop.example"])
    end

    it "drops a blank or unparseable entry rather than raising" do
      handoff_only = described_class.new(config: config("handoff_only_hosts" => ["  ", "", "https://"]))

      expect(handoff_only.hosts).to eq([])
    end

    it "a normalized www./URL entry still matches through #host?" do
      handoff_only = described_class.new(config: config("handoff_only_hosts" => ["https://www.shop.example/"]))

      expect(handoff_only.host?("shop.example")).to be true
      expect(handoff_only.host?("checkout.shop.example")).to be true
    end
  end

  describe "#host?" do
    it "matches the bare host and any subdomain, case-insensitively" do
      handoff_only = described_class.new(config: config)

      expect(handoff_only.host?("amazon.co.uk")).to be true
      expect(handoff_only.host?("www.amazon.co.uk")).to be true
      expect(handoff_only.host?("SMILE.AMAZON.COM")).to be true
    end

    it "never matches on a substring — a host merely containing 'amazon' isn't on the list" do
      handoff_only = described_class.new(config: config)

      expect(handoff_only.host?("notamazon.com")).to be false
      expect(handoff_only.host?("amazon.com.evil.example")).to be false
    end

    it "is false for nil/blank" do
      handoff_only = described_class.new(config: config)

      expect(handoff_only.host?(nil)).to be false
      expect(handoff_only.host?("")).to be false
    end

    it "reflects a user-configured host once the key is present" do
      handoff_only = described_class.new(config: config("handoff_only_hosts" => ["shop.example"]))

      expect(handoff_only.host?("shop.example")).to be true
      expect(handoff_only.host?("amazon.com")).to be false
    end
  end

  describe ".amazon?" do
    it "is true for an Amazon marketplace regardless of the user's own configured list" do
      expect(described_class.amazon?("www.amazon.de")).to be true
    end

    it "is false for a non-Amazon host" do
      expect(described_class.amazon?("shop.example")).to be false
    end
  end

  it "carries the as-is/no-warranty disclaimer" do
    expect(described_class::LEGAL_NOTICE).to include("provided as-is, without warranty")
    expect(described_class::LEGAL_NOTICE).to include("restrict automated purchasing agents")
  end
end
