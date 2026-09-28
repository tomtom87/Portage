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

  # Phase 2's own PORTAGE_PROXY* vars (docs/plans/proxy-support.md) are
  # nulled here too, same reasoning as the http_proxy/HTTPS_PROXY pair
  # already were — a real one set in the shell running these specs would
  # otherwise make ProxyDoctor add findings and break the exact match below.
  def no_proxy_env
    { "http_proxy" => nil, "HTTP_PROXY" => nil, "https_proxy" => nil, "HTTPS_PROXY" => nil,
      "PORTAGE_PROXY" => nil, "PORTAGE_PROXY_MODE" => nil, "PORTAGE_NO_PROXY" => nil,
      "PORTAGE_PROXY_CA" => nil, "PORTAGE_PROXY_HEADERS" => nil }
  end

  # InstallDoctor's own findings (install/runtime/adapters/path) are covered
  # in install_doctor_spec.rb against a fake filesystem; here it gets an
  # empty PATH so the real one can't add a shadowing warning.
  let(:install_doctor) { Portage::Cli::InstallDoctor.new(path: "") }

  def shipping_env
    { "PORTAGE_SHIP_STREET" => "1 Main St", "PORTAGE_SHIP_CITY" => "Erie", "PORTAGE_SHIP_COUNTRY" => "US",
      "PORTAGE_SHIP_POSTAL_CODE" => "16501" }
  end

  def warnings(**opts) = described_class.new(install_doctor: install_doctor, **opts).call.select(&:warning?)

  it "flags every collaborator still at its unconfigured default" do
    with_env(no_proxy_env.merge(shipping_env).merge("PORTAGE_DECISION_BACKEND" => nil)) do
      expect(warnings.map(&:check)).to contain_exactly("authenticator", "rate_limiter", "signing_keys",
                                                       "payment_handlers")
    end
  end

  it "leads with the install/runtime/adapters report as info, not warnings" do
    findings = with_env(no_proxy_env) { described_class.new(install_doctor: install_doctor).call }

    expect(findings.first(3).map(&:check)).to eq(%w[install runtime adapters])
    expect(findings.first(3)).to all(satisfy { |f| !f.warning? })
  end

  it "keeps to_h free of empty details, so --json output of existing checks is unchanged but for level" do
    finding = described_class::Finding.new(check: "x", message: "y")

    expect(finding.to_h).to eq(check: "x", message: "y", level: "warning")
  end

  describe "seller checks" do
    it "skips them, with one info line saying how to run them, when seller: false" do
      findings = with_env(no_proxy_env.merge(shipping_env)) do
        described_class.new(install_doctor: install_doctor, seller: false).call
      end

      expect(findings.map(&:check)).not_to include("authenticator", "rate_limiter", "signing_keys",
                                                   "payment_handlers")
      seller = findings.find { |f| f.check == "seller" }
      expect(seller).not_to be_warning
      expect(seller.message).to include("--require")
    end
  end

  describe "the env file" do
    around do |example|
      Dir.mktmpdir do |dir|
        @env_path = File.join(dir, ".env")
        File.write(@env_path, "PORTAGE_SHIP_CITY=Erie\n")
        example.run
      end
    end

    def env_finding(mode)
      File.chmod(mode, @env_path)
      with_env(no_proxy_env) do
        described_class.new(install_doctor: install_doctor, dot_env_path: @env_path).call
                       .find { |f| f.check == "env_file" }
      end
    end

    it "reports which file was loaded" do
      finding = env_finding(0o600)

      expect(finding).not_to be_warning
      expect(finding.details).to eq(path: @env_path, mode: "600")
    end

    it "warns when other users can read it" do
      finding = env_finding(0o644)

      expect(finding).to be_warning
      expect(finding.message).to include("chmod 600")
    end

    it "says nothing when no env file was loaded" do
      findings = with_env(no_proxy_env) { described_class.new(install_doctor: install_doctor, dot_env_path: nil).call }

      expect(findings.map(&:check)).not_to include("env_file")
    end
  end

  describe "the shipping address" do
    def shipping_finding(env)
      blank = shipping_env.transform_values { nil }
      with_env(no_proxy_env.merge(blank).merge(env)) { warnings.find { |f| f.check == "shipping" } }
    end

    it "says nothing once every required PORTAGE_SHIP_* field is set" do
      expect(shipping_finding(shipping_env)).to be_nil
    end

    it "names every required variable when none are set, including the market consequence" do
      finding = shipping_finding({})

      expect(finding.message).to include("No shipping address set", "PORTAGE_SHIP_STREET", "PORTAGE_SHIP_CITY",
                                         "PORTAGE_SHIP_COUNTRY", "PORTAGE_SHIP_POSTAL_CODE", "out of stock",
                                         ".env.example")
    end

    it "names only the missing ones for a partial address, treating an empty value as unset" do
      finding = shipping_finding(shipping_env.merge("PORTAGE_SHIP_CITY" => "", "PORTAGE_SHIP_POSTAL_CODE" => nil))

      expect(finding.message).to include("missing PORTAGE_SHIP_CITY, PORTAGE_SHIP_POSTAL_CODE", "treated as none")
      expect(finding.message).not_to include("out of stock")
    end
  end

  it "clears a finding once its collaborator is configured" do
    Portage::Ucp.configure do |config|
      config.authenticator = ->(_ctx) { "auth-context" }
      config.rate_limiter = Class.new { def check!(*); end }.new
      config.signing_keys = [{ kid: "k1" }]
      config.payment_handlers = [{ name: "stripe" }]
    end

    with_env(no_proxy_env.merge(shipping_env).merge("PORTAGE_DECISION_BACKEND" => "jev",
                                                    "JEV_API_KEY" => "test-key")) do
      expect(warnings).to be_empty
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

  describe "the search backend used by find/buy without a url" do
    def no_key_env
      { "BRAVE_SEARCH_API_KEY" => nil, "GOOGLE_CSE_KEY" => nil, "GOOGLE_CSE_CX" => nil, "PORTAGE_STORES" => nil }
    end

    def search_backend_finding(env = {})
      with_env(no_key_env.merge(env)) do
        allow(Portage::Cli::SearchBackends::Allowlist).to receive(:new)
          .and_return(instance_double(Portage::Cli::SearchBackends::Allowlist, available?: false))
        described_class.new.call.find { |f| f.check == "search_backend" }
      end
    end

    it "flags a duckduckgo-only setup as an info finding, not a warning" do
      finding = search_backend_finding

      expect(finding.level).to eq("info")
      expect(finding.message).to include("BRAVE_SEARCH_API_KEY", "GOOGLE_CSE_KEY", "GOOGLE_CSE_CX",
                                         "stores.yml")
    end

    it "says nothing once a keyed backend is configured" do
      expect(search_backend_finding("BRAVE_SEARCH_API_KEY" => "test-key")).to be_nil
    end

    it "says nothing once an allowlist is in play" do
      with_env(no_key_env) do
        allow(Portage::Cli::SearchBackends::Allowlist).to receive(:new)
          .and_return(instance_double(Portage::Cli::SearchBackends::Allowlist, available?: true))

        expect(described_class.new.call.find { |f| f.check == "search_backend" }).to be_nil
      end
    end
  end

  describe "the agent profile used by find/buy" do
    def agent_profile_finding(env = {})
      with_env(env) { described_class.new.call.find { |f| f.check == "agent_profile" } }
    end

    it "says which profile is in use when PORTAGE_AGENT_PROFILE is set" do
      finding = agent_profile_finding("PORTAGE_AGENT_PROFILE" => "https://example.com/agent-profile.json")

      expect(finding.level).to eq("info")
      expect(finding.message).to include("https://example.com/agent-profile.json")
    end

    it "names the repo's own published profile as the fallback when unset" do
      finding = agent_profile_finding("PORTAGE_AGENT_PROFILE" => nil)

      expect(finding.level).to eq("info")
      expect(finding.message).to include("PORTAGE_AGENT_PROFILE not set", Portage::Cli::AgentProfileUrl::DEFAULT)
    end
  end

  describe "the local index (docs/plans/buy-skill-and-local-browser.md Phase 2b)" do
    def index_finding(stores:, products:, known_cache: instance_double(Portage::Cli::Index::KnownCache,
                                                                       stale?: false, exists?: false))
      described_class.new(install_doctor: install_doctor, index_stores: stores, index_products: products,
                          known_cache: known_cache).call.find { |f| f.check == "index" }
    end

    it "says there's no index yet when stores.json doesn't exist" do
      stores = instance_double(Portage::Cli::Index::Store, exists?: false)
      products = instance_double(Portage::Cli::Index::ProductStore)

      finding = index_finding(stores: stores, products: products)

      expect(finding.level).to eq("info")
      expect(finding.message).to include("No local index yet", "portage index build")
    end

    it "reports counts and staleness once one exists" do
      stores = instance_double(Portage::Cli::Index::Store, exists?: true, all: [1, 2], oldest_verified_age: 3 * 86_400)
      products = instance_double(Portage::Cli::Index::ProductStore, all: [1, 2, 3])

      finding = index_finding(stores: stores, products: products)

      expect(finding.level).to eq("info")
      expect(finding.message).to include("2 store(s)", "3 product(s)", "3 day(s) ago")
    end

    describe "the known-stores cache (Phase 2c)" do
      let(:stores) { instance_double(Portage::Cli::Index::Store, exists?: false) }
      let(:products) { instance_double(Portage::Cli::Index::ProductStore) }

      it "says it hasn't been fetched yet when there's no cache" do
        known_cache = instance_double(Portage::Cli::Index::KnownCache, stale?: true, exists?: false)
        allow(known_cache).to receive(:refresh!)

        finding = index_finding(stores: stores, products: products, known_cache: known_cache)

        expect(finding.message).to include("not fetched yet")
      end

      it "reports the known cache's own counts and age once it exists" do
        known_stores = { "a" => {}, "b" => {} }
        known_products = { "c" => {} }
        known_cache = instance_double(
          Portage::Cli::Index::KnownCache, stale?: false, exists?: true, age: 2 * 86_400,
                                           stores: known_stores, products: known_products
        )

        finding = index_finding(stores: stores, products: products, known_cache: known_cache)

        expect(finding.message).to include("2 store(s)", "1 product(s)", "2 day(s) ago")
      end

      it "refreshes the known cache when it's stale, and never raises if that fails" do
        known_cache = instance_double(Portage::Cli::Index::KnownCache, exists?: false)
        allow(known_cache).to receive(:stale?).and_return(true)
        allow(known_cache).to receive(:refresh!).and_raise(StandardError, "offline")

        expect { index_finding(stores: stores, products: products, known_cache: known_cache) }.not_to raise_error
      end

      it "doesn't refresh the known cache when it isn't stale" do
        known_cache = instance_double(Portage::Cli::Index::KnownCache, stale?: false, exists?: true, age: 60,
                                                                       stores: {}, products: {})
        allow(known_cache).to receive(:refresh!)

        index_finding(stores: stores, products: products, known_cache: known_cache)

        expect(known_cache).not_to have_received(:refresh!)
      end
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

  # docs/plans/buy-skill-and-local-browser.md Phase 4 — the trigger for
  # `doctor`/`configure` to offer the setup wizard on a TTY (Cli.run_wizard?).
  # Conservative by design: any one of the three foundational settings being
  # present at all is enough to call this a real, if partial, setup.
  describe "#nothing_configured?" do
    def unset_shipping_env = Portage::Cli::ShippingProfile::ENV_VARS.values.to_h { |var| [var, nil] }

    def nothing_configured?(dot_env_path:, env: {})
      with_env(no_proxy_env.merge(unset_shipping_env).merge(env)) do
        described_class.new(install_doctor: install_doctor, dot_env_path: dot_env_path).nothing_configured?
      end
    end

    it "is true with no env file, no shipping address and no policy" do
      expect(nothing_configured?(dot_env_path: nil)).to be(true)
    end

    it "is false once an env file was loaded, even with nothing else set" do
      expect(nothing_configured?(dot_env_path: "/wherever/.env")).to be(false)
    end

    it "is false once a shipping address is set, with no env file loaded" do
      expect(nothing_configured?(dot_env_path: nil, env: shipping_env)).to be(false)
    end

    it "is false once any policy at all is set, with no env file or shipping address" do
      Portage::Ucp::Policy.load.set("merchant_allowlist", ["shop.example.com"])

      expect(nothing_configured?(dot_env_path: nil)).to be(false)
    end
  end
end
