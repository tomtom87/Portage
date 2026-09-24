require "spec_helper"

RSpec.describe Portage::Cli::Doctor do
  # Portage::Ucp.configuration memoizes a single Configuration instance —
  # reset it around each example so one test's config.signing_keys= etc.
  # doesn't leak into the next.
  around do |example|
    Portage::Ucp.instance_variable_set(:@configuration, nil)
    example.run
    Portage::Ucp.instance_variable_set(:@configuration, nil)
  end

  it "flags every collaborator still at its unconfigured default" do
    with_env("PORTAGE_DECISION_BACKEND" => nil, "http_proxy" => nil, "HTTP_PROXY" => nil, "https_proxy" => nil,
             "HTTPS_PROXY" => nil) do
      findings = described_class.new.call

      expect(findings.map(&:check)).to contain_exactly("authenticator", "rate_limiter", "signing_keys",
                                                       "payment_handlers")
    end
  end

  it "clears a finding once its collaborator is configured" do
    Portage::Ucp.configure do |config|
      config.authenticator = ->(_ctx) { "auth-context" }
      config.rate_limiter = Class.new { def check!(*); end }.new
      config.signing_keys = [{ kid: "k1" }]
      config.payment_handlers = [{ name: "stripe" }]
    end

    with_env("PORTAGE_DECISION_BACKEND" => "jev", "JEV_API_KEY" => "test-key", "http_proxy" => nil,
             "HTTP_PROXY" => nil, "https_proxy" => nil, "HTTPS_PROXY" => nil) do
      expect(described_class.new.call).to be_empty
    end
  end

  describe "the confidence gate's backend" do
    def decision_finding(env)
      with_env({ "JEV_API_KEY" => nil, "TYPESAFE_API_KEY" => nil, "PORTAGE_MIN_CONFIDENCE" => nil }.merge(env)) do
        described_class.new.call.find { |f| f.check == "decision_backend" }
      end
    end

    it "says nothing when no backend is selected, even with no JEV_API_KEY" do
      expect(decision_finding("PORTAGE_DECISION_BACKEND" => nil)).to be_nil
    end

    it "flags a missing JEV_API_KEY once jev is selected, with a link to get one" do
      finding = decision_finding("PORTAGE_DECISION_BACKEND" => "jev")

      expect(finding.message).to include("JEV_API_KEY", "console.typesafe.ai", "held for the shopper")
    end

    it "accepts TYPESAFE_API_KEY in place of JEV_API_KEY, since ModelBackends::Jev falls back to it" do
      expect(decision_finding("PORTAGE_DECISION_BACKEND" => "jev", "TYPESAFE_API_KEY" => "test-key")).to be_nil
    end

    it "flags laya selected with no bridge configured" do
      finding = decision_finding("PORTAGE_DECISION_BACKEND" => "laya", "LAYA_BRIDGE_SCRIPT" => nil,
                                 "LAYA_INFER_COMMAND" => nil)

      expect(finding.message).to include("LAYA_BRIDGE_SCRIPT")
    end

    it "flags an unknown backend name" do
      expect(decision_finding("PORTAGE_DECISION_BACKEND" => "nope").message).to include("unknown", "jev, laya")
    end

    it "flags a backend selected without portage-ucp-decision installed" do
      allow(Portage::Cli::Decisions).to receive(:available?).and_return(false)

      expect(decision_finding("PORTAGE_DECISION_BACKEND" => "jev").message).to include("gem install")
    end

    it "flags a bad PORTAGE_MIN_CONFIDENCE" do
      finding = decision_finding("PORTAGE_DECISION_BACKEND" => "jev", "PORTAGE_MIN_CONFIDENCE" => "high")

      expect(finding.message).to include("between 0.0 and 1.0")
    end
  end

  describe "the configured User-Agent" do
    before { allow(Portage::Cli::Config).to receive(:load).and_return(Portage::Cli::Config.new(data: {})) }

    def user_agent_finding(value)
      with_env("PORTAGE_USER_AGENT" => value) do
        described_class.new.call.find { |f| f.check == "user_agent" }
      end
    end

    it "says nothing about the default" do
      expect(user_agent_finding(nil)).to be_nil
    end

    it "says nothing about a clean override" do
      expect(user_agent_finding("my-agent/1.0")).to be_nil
    end

    it "flags an override containing a newline, since Net::HTTP would raise on it mid-checkout" do
      finding = user_agent_finding("my-agent/1.0\nX-Injected: yes")

      expect(finding.message).to include("PORTAGE_USER_AGENT", "newline")
    end
  end

  it "flags a capability implemented on some but not all of its actions" do
    adapter_class = Class.new(Portage::Ucp::Adapter) do
      def search_catalog(**) = []
    end

    findings = described_class.new(adapter_class: adapter_class).call

    catalog_finding = findings.find { |f| f.check == "capability:dev.ucp.shopping.catalog" }
    expect(catalog_finding.message).to include("1/3")
  end

  it "doesn't flag a capability with none or all of its actions implemented" do
    untouched_adapter = Class.new(Portage::Ucp::Adapter)

    findings = described_class.new(adapter_class: untouched_adapter).call

    expect(findings.map(&:check)).to all(satisfy { |c| !c.start_with?("capability:") })
  end

  describe "the proxy check (Phase 0 of docs/plans/proxy-support.md)" do
    def proxy_finding(env)
      base = { "http_proxy" => nil, "HTTP_PROXY" => nil, "https_proxy" => nil, "HTTPS_PROXY" => nil,
               "no_proxy" => nil, "NO_PROXY" => nil }
      with_env(base.merge(env)) { described_class.new.call.find { |f| f.check == "proxy" } }
    end

    it "says nothing when no proxy env var is set" do
      expect(proxy_finding({})).to be_nil
    end

    it "reports the effective proxy, with credentials redacted, when http_proxy is set" do
      finding = proxy_finding("http_proxy" => "http://bob:s3cr3t@proxy.internal:3128")

      expect(finding.message).to include("http://***@proxy.internal:3128")
      expect(finding.message).not_to include("bob", "s3cr3t")
    end

    it "names HTTP_PROXY as the source when only the uppercase variant is set" do
      expect(proxy_finding("HTTP_PROXY" => "http://proxy.internal:3128").message).to include("HTTP_PROXY")
    end

    it "mentions the active no_proxy value" do
      finding = proxy_finding("http_proxy" => "http://proxy.internal:3128", "no_proxy" => "localhost,127.0.0.1")

      expect(finding.message).to include("no_proxy=localhost,127.0.0.1")
    end

    it "flags HTTPS_PROXY set alone as not doing anything for these call sites" do
      finding = proxy_finding("https_proxy" => "http://proxy.internal:3128")

      expect(finding.message).to include("HTTPS_PROXY/https_proxy is set but http_proxy/HTTP_PROXY is not")
    end

    it "prefers the working http_proxy report over the gap warning when both are set" do
      finding = proxy_finding("http_proxy" => "http://proxy.internal:3128", "https_proxy" => "http://other:3128")

      expect(finding.message).to include("proxy.internal:3128")
      expect(finding.message).not_to include("is not")
    end
  end
end
