require "spec_helper"

RSpec.describe Portage::Cli::BrowserProfile::Allowlist do
  it "allows the seeded host and its subdomains, not an unrelated host" do
    allowlist = described_class.new(hosts: ["example.com"])

    expect(allowlist.allowed?("example.com")).to be true
    expect(allowlist.allowed?("www.example.com")).to be true
    expect(allowlist.allowed?("checkout.example.com")).to be true
    expect(allowlist.allowed?("evil-example.com")).to be false
    expect(allowlist.allowed?("other.com")).to be false
  end

  it "normalizes a seeded host the same way HandoffOnly does (scheme, www, path)" do
    allowlist = described_class.new(hosts: ["https://www.example.com/s?q=x"])

    expect(allowlist.hosts).to eq(["example.com"])
  end

  it "never allows a bogus/blank host" do
    allowlist = described_class.new(hosts: ["example.com"])

    expect(allowlist.allowed?(nil)).to be false
    expect(allowlist.allowed?("")).to be false
  end

  describe "#permit!" do
    it "grows the allowlist so a newly permitted host is allowed afterward" do
      allowlist = described_class.new(hosts: ["example.com"])

      expect(allowlist.allowed?("checkout.other.com")).to be false
      allowlist.permit!("https://checkout.other.com/pay")
      expect(allowlist.allowed?("checkout.other.com")).to be true
    end

    it "is idempotent — permitting an already-allowed host doesn't duplicate it" do
      allowlist = described_class.new(hosts: ["example.com"])

      allowlist.permit!("example.com")
      expect(allowlist.hosts).to eq(["example.com"])
    end

    it "returns nil and changes nothing for a value with no host" do
      allowlist = described_class.new(hosts: ["example.com"])

      expect(allowlist.permit!("   ")).to be_nil
      expect(allowlist.hosts).to eq(["example.com"])
    end
  end
end
