require "spec_helper"
require "support/local_proxy"

# ProxyDoctor's reachability check dials a real socket (through Support::
# Connection, the same code every real request uses) rather than faking it,
# so — same as proxy_support_spec.rb — WebMock's global disable_net_connect!
# is loosened for the duration of these examples. Every host below is
# either 127.0.0.1 (a real LocalProxy) or an RFC 2606 .invalid hostname that
# can't resolve, so nothing here touches the real network.
RSpec.describe Portage::Cli::ProxyDoctor do
  around do |example|
    WebMock.allow_net_connect!
    example.run
  ensure
    WebMock.disable_net_connect!
  end

  def cfg(data) = Portage::Cli::Config.new(data: data)

  def settings(flags: {}, config: cfg({})) = Portage::Cli::ProxySettings.new(flags: flags, config: config)

  describe "effective routing, credentials always redacted" do
    it "reports nothing when no proxy is configured at all" do
      findings = described_class.new(proxy_settings: settings).findings

      expect(findings).to be_empty
    end

    it "shows every fixed route, with the default profile's credentials redacted" do
      s = settings(flags: { proxy: "http://bob:s3cr3t@egress.invalid:3128" })

      finding = described_class.new(proxy_settings: s, config: cfg({}), timeout: 1)
                               .findings.find { |f| f.check == "proxy_routes" }

      expect(finding.message).to include("http://***@egress.invalid:3128")
      expect(finding.message).not_to include("bob", "s3cr3t")
      expect(finding.message).to include("payment: direct")
    end
  end

  describe "reachability" do
    it "reports nothing for a reachable forward proxy" do
      proxy = LocalProxy.new
      s = settings(flags: { proxy: "http://#{proxy.host}:#{proxy.port}" })

      findings = described_class.new(proxy_settings: s, config: cfg({}), probe_uri: URI("http://probe.invalid/"))
                                .findings

      expect(findings.map(&:check)).not_to include("proxy_reachability")
    ensure
      proxy&.stop
    end

    it "flags a forward proxy that refuses the connection" do
      s = settings(flags: { proxy: "http://127.0.0.1:1" })

      finding = described_class.new(proxy_settings: s, config: cfg({}), probe_uri: URI("http://probe.invalid/"),
                                    timeout: 1).findings.find { |f| f.check == "proxy_reachability" }

      expect(finding).not_to be_nil
      expect(finding.message).to include("http://127.0.0.1:1")
    end

    it "reports nothing when the gateway answers" do
      proxy = LocalProxy.new
      s = settings(flags: { proxy: "http://#{proxy.host}:#{proxy.port}", proxy_mode: "gateway" })

      findings = described_class.new(proxy_settings: s, config: cfg({}), probe_uri: URI("http://probe.invalid/"))
                                .findings

      expect(findings.map(&:check)).not_to include("proxy_reachability")
    ensure
      proxy&.stop
    end
  end

  describe "plaintext credential warning" do
    it "flags a default profile whose url carries a plaintext password" do
      config = cfg({ "proxy" => { "default" => { "url" => "http://bob:s3cr3t@egress.invalid:3128" } } })
      s = settings(config: config)

      finding = described_class.new(proxy_settings: s, config: config, timeout: 1)
                               .findings.find { |f| f.check == "proxy_credentials" }

      expect(finding).not_to be_nil
      expect(finding.message).not_to include("bob", "s3cr3t")
    end

    it "says nothing when the url has no userinfo" do
      config = cfg({ "proxy" => { "default" => { "url" => "http://egress.invalid:3128" } } })
      s = settings(config: config)

      findings = described_class.new(proxy_settings: s, config: config, timeout: 1).findings

      expect(findings.map(&:check)).not_to include("proxy_credentials")
    end

    it "says nothing when a password_ref is used instead of a literal password" do
      allow(Portage::Cli::ProxySettings::PasswordRef).to receive(:resolve).and_return("s3cr3t")
      config = cfg({ "proxy" => { "default" => { "url" => "http://bob@egress.invalid:3128",
                                                 "password_ref" => "egress" } } })
      s = settings(config: config)

      findings = described_class.new(proxy_settings: s, config: config, timeout: 1).findings

      expect(findings.map(&:check)).not_to include("proxy_credentials")
    end
  end

  describe "payment-route intercept warning" do
    it "flags an explicit gateway on the payment route" do
      config = cfg({ "proxy" => { "routes" =>
                                  { "payment" => { "mode" => "gateway", "url" => "https://gw.invalid/fetch" } } } })
      s = settings(config: config)

      finding = described_class.new(proxy_settings: s, config: config, timeout: 1)
                               .findings.find { |f| f.check == "proxy_payment_intercept" }

      expect(finding).not_to be_nil
    end

    it "flags a ca_file (TLS-intercepting) proxy on the payment route" do
      config = cfg({ "proxy" => { "routes" =>
                                  { "payment" => { "url" => "http://p.invalid:3128",
                                                   "ca_file" => "/tmp/corp-ca.pem" } } } })
      s = settings(config: config)

      finding = described_class.new(proxy_settings: s, config: config, timeout: 1)
                               .findings.find { |f| f.check == "proxy_payment_intercept" }

      expect(finding).not_to be_nil
    end

    it "says nothing when payment stays on its direct default" do
      s = settings(flags: { proxy: "http://p.invalid:3128", proxy_mode: "gateway" })

      findings = described_class.new(proxy_settings: s, config: cfg({}), timeout: 1).findings

      expect(findings.map(&:check)).not_to include("proxy_payment_intercept")
    end
  end
end
