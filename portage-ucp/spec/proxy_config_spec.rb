# frozen_string_literal: true

require "spec_helper"

RSpec.describe Portage::Ucp::Support::ProxyConfig do
  after { described_class.current = nil }

  describe ".current" do
    it "defaults to a fully-direct config" do
      expect(described_class.current.chain_for(:anything, host: "shop.example.com")).to eq(
        [Portage::Ucp::Support::ProxyConfig::Profile::DIRECT]
      )
    end

    it "can be overridden and read back" do
      custom = described_class.new
      described_class.current = custom
      expect(described_class.current).to equal(custom)
    end
  end

  describe ".host_matches?" do
    it "matches an exact entry" do
      expect(described_class.host_matches?("shop.example.com", ["shop.example.com"])).to be(true)
    end

    it "matches a subdomain against a bare entry" do
      expect(described_class.host_matches?("api.shop.example.com", ["shop.example.com"])).to be(true)
    end

    it "matches a subdomain against a leading-dot entry" do
      expect(described_class.host_matches?("api.shop.example.com", [".shop.example.com"])).to be(true)
    end

    it "treats a leading dot as equivalent to a bare entry (simplified vs. Phase 0's asymmetric stdlib findings)" do
      expect(described_class.host_matches?("shop.example.com", [".shop.example.com"])).to be(true)
    end

    it "matches everything for a bare *" do
      expect(described_class.host_matches?("anything.at.all", ["*"])).to be(true)
    end

    it "is case-insensitive" do
      expect(described_class.host_matches?("SHOP.EXAMPLE.COM", ["shop.example.com"])).to be(true)
    end

    it "does not match an unrelated host" do
      expect(described_class.host_matches?("other.com", ["shop.example.com"])).to be(false)
    end
  end

  describe "Profile" do
    it "requires a url for anything but :direct" do
      expect { described_class::Profile.new(mode: :forward, url: nil) }.to raise_error(described_class::ConfigError)
    end

    it "rejects an unknown mode" do
      expect { described_class::Profile.new(mode: :bogus, url: "http://proxy.example:3128") }
        .to raise_error(described_class::ConfigError, /unknown proxy mode/)
    end

    it "does not require a url for :direct" do
      expect { described_class::Profile.new(mode: :direct) }.not_to raise_error
    end
  end

  describe "#chain_for" do
    it "resolves a chain (Array) route to an Array of Profiles" do
      config = described_class.new(routes: {
                                     "platform" => [{ mode: :forward, url: "http://a.example:1" },
                                                    { mode: :forward, url: "http://b.example:2" }]
                                   })
      chain = config.chain_for(:platform, host: "shop.example.com")
      expect(chain.length).to eq(2)
      expect(chain.map(&:mode)).to eq(%i[forward forward])
    end

    it "raises for a named profile that doesn't exist" do
      config = described_class.new(routes: { "platform" => "nonexistent" })
      expect { config.chain_for(:platform, host: "shop.example.com") }.to raise_error(described_class::ConfigError)
    end

    it "resolves a named profile by string or symbol route key interchangeably" do
      config = described_class.new(profiles: { "corp" => { mode: :forward, url: "http://corp.example:3128" } },
                                   routes: { "platform" => "corp" })
      expect(config.chain_for("platform", host: "x").first.url).to eq("http://corp.example:3128")
      expect(config.chain_for(:platform, host: "x").first.url).to eq("http://corp.example:3128")
    end
  end
end
