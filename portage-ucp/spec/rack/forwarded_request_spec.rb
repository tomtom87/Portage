require "spec_helper"
require "rack"

RSpec.describe Portage::Ucp::Rack::ForwardedRequest do
  def request_for(remote_addr:, headers: {})
    env = Rack::MockRequest.env_for("/", method: "GET", "REMOTE_ADDR" => remote_addr)
    headers.each { |name, value| env["HTTP_#{name.upcase.tr('-', '_')}"] = value }
    Rack::Request.new(env)
  end

  describe ".validate_passthrough!" do
    it "raises for a protected header" do
      expect { described_class.validate_passthrough!(%w[Authorization]) }
        .to raise_error(Portage::Ucp::Support::ProxyConfig::ConfigError, /Authorization/)
    end

    it "raises for the Shopify access token family" do
      expect { described_class.validate_passthrough!(["X-Shopify-Admin-Access-Token"]) }
        .to raise_error(Portage::Ucp::Support::ProxyConfig::ConfigError)
    end

    it "accepts an ordinary header" do
      expect { described_class.validate_passthrough!(%w[X-Request-Id]) }.not_to raise_error
    end
  end

  describe "#peer_trusted?" do
    it "is false with no trusted_proxies configured (fail-closed default)" do
      forwarded = described_class.new(request_for(remote_addr: "10.0.0.5"), trusted_proxies: [])

      expect(forwarded.peer_trusted?).to be(false)
    end

    it "is true when the peer is inside a configured CIDR" do
      forwarded = described_class.new(request_for(remote_addr: "10.0.0.5"), trusted_proxies: ["10.0.0.0/8"])

      expect(forwarded.peer_trusted?).to be(true)
    end

    it "is false when the peer is outside every configured CIDR" do
      forwarded = described_class.new(request_for(remote_addr: "203.0.113.9"), trusted_proxies: ["10.0.0.0/8"])

      expect(forwarded.peer_trusted?).to be(false)
    end
  end

  describe "#client_ip" do
    it "ignores X-Forwarded-For from an untrusted peer, falling back to the socket peer" do
      forwarded = described_class.new(
        request_for(remote_addr: "203.0.113.9", headers: { "x-forwarded-for" => "198.51.100.7" }),
        trusted_proxies: []
      )

      expect(forwarded.client_ip).to eq("203.0.113.9")
    end

    it "reads the right-most untrusted hop as the client, from a trusted peer" do
      # 10.0.0.5 (the peer) forwarded a chain built by two trusted internal
      # hops (10.0.0.1, 10.0.0.2) in front of the real, untrusted client.
      forwarded = described_class.new(
        request_for(remote_addr: "10.0.0.5",
                    headers: { "x-forwarded-for" => "198.51.100.7, 10.0.0.1, 10.0.0.2" }),
        trusted_proxies: ["10.0.0.0/8"]
      )

      expect(forwarded.client_ip).to eq("198.51.100.7")
    end

    it "falls back to the left-most entry when every hop in the chain is itself trusted" do
      forwarded = described_class.new(
        request_for(remote_addr: "10.0.0.5", headers: { "x-forwarded-for" => "10.0.0.1, 10.0.0.2" }),
        trusted_proxies: ["10.0.0.0/8"]
      )

      expect(forwarded.client_ip).to eq("10.0.0.1")
    end

    it "parses the RFC 7239 Forwarded header the same way, from a trusted peer" do
      forwarded = described_class.new(
        request_for(remote_addr: "10.0.0.5",
                    headers: { "forwarded" => "for=198.51.100.7, for=10.0.0.2" }),
        trusted_proxies: ["10.0.0.0/8"]
      )

      expect(forwarded.client_ip).to eq("198.51.100.7")
    end

    it "strips a port from an IPv4 X-Forwarded-For entry" do
      forwarded = described_class.new(
        request_for(remote_addr: "10.0.0.5", headers: { "x-forwarded-for" => "198.51.100.7:4433" }),
        trusted_proxies: ["10.0.0.0/8"]
      )

      expect(forwarded.client_ip).to eq("198.51.100.7")
    end

    it "strips brackets and a port from a bracketed IPv6 entry" do
      forwarded = described_class.new(
        request_for(remote_addr: "10.0.0.5", headers: { "x-forwarded-for" => "[2001:db8::1]:4433" }),
        trusted_proxies: ["10.0.0.0/8"]
      )

      expect(forwarded.client_ip).to eq("2001:db8::1")
    end
  end

  describe "#own_origin / #forwarded_host_allowed?" do
    it "never widens which host counts as the endpoint's own without an explicit allowlist" do
      forwarded = described_class.new(
        request_for(remote_addr: "10.0.0.5", headers: { "x-forwarded-host" => "evil.example" }),
        trusted_proxies: ["10.0.0.0/8"]
      )

      expect(forwarded.forwarded_host_allowed?([])).to be(false)
      expect(forwarded.own_origin(forwarded_host_allowed: [])).to eq("http://example.org")
    end

    it "replaces own_origin only when the forwarded host is explicitly allowed AND the peer is trusted" do
      forwarded = described_class.new(
        request_for(remote_addr: "10.0.0.5", headers: { "x-forwarded-host" => "shop.example",
                                                        "x-forwarded-proto" => "https" }),
        trusted_proxies: ["10.0.0.0/8"]
      )

      expect(forwarded.own_origin(forwarded_host_allowed: ["shop.example"])).to eq("https://shop.example")
    end

    it "ignores a spoofed X-Forwarded-Host from an untrusted peer even if it's on the allowlist" do
      forwarded = described_class.new(
        request_for(remote_addr: "203.0.113.9", headers: { "x-forwarded-host" => "shop.example" }),
        trusted_proxies: ["10.0.0.0/8"]
      )

      expect(forwarded.own_origin(forwarded_host_allowed: ["shop.example"])).to eq("http://example.org")
    end
  end

  describe "#passthrough_headers" do
    it "returns nothing from an untrusted peer" do
      forwarded = described_class.new(
        request_for(remote_addr: "203.0.113.9", headers: { "x-shop-locale" => "en-GB" }),
        trusted_proxies: ["10.0.0.0/8"]
      )

      expect(forwarded.passthrough_headers(%w[X-Shop-Locale])).to eq({})
    end

    it "returns the allowlisted headers, verbatim, from a trusted peer" do
      forwarded = described_class.new(
        request_for(remote_addr: "10.0.0.5", headers: { "x-shop-locale" => "en-GB" }),
        trusted_proxies: ["10.0.0.0/8"]
      )

      expect(forwarded.passthrough_headers(%w[X-Shop-Locale])).to eq({ "X-Shop-Locale" => "en-GB" })
    end
  end
end
