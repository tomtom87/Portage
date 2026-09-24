require "spec_helper"

RSpec.describe Portage::Cli::ProxySettings do
  def direct = Portage::Ucp::Support::ProxyConfig::Profile::DIRECT

  def cfg(data) = Portage::Cli::Config.new(data: data)

  def resolve(flags: {}, config: cfg({})) = described_class.new(flags: flags, config: config).resolve

  describe "precedence: flag > env > config.json, per field (not whole-object)" do
    let(:config) do
      cfg({ "proxy" => { "default" => { "url" => "http://config-proxy:3128",
                                        "no_proxy" => ["config.example"] } } })
    end

    it "a flag --proxy overrides default.url but keeps config.json's no_proxy" do
      pc = resolve(flags: { proxy: "http://flag-proxy:3128" }, config: config)

      expect(pc.chain_for(:store, host: "shop.example").first.url).to eq("http://flag-proxy:3128")
      expect(pc.no_proxy).to eq(["config.example"])
    end

    it "PORTAGE_PROXY overrides config.json when no flag is given" do
      with_env("PORTAGE_PROXY" => "http://env-proxy:3128") do
        pc = resolve(config: config)

        expect(pc.chain_for(:store, host: "shop.example").first.url).to eq("http://env-proxy:3128")
        expect(pc.no_proxy).to eq(["config.example"])
      end
    end

    it "config.json alone is used when neither a flag nor an env var is set" do
      pc = resolve(config: config)

      expect(pc.chain_for(:store, host: "shop.example").first.url).to eq("http://config-proxy:3128")
    end

    it "resolves mode and ca_file independently of url's own source" do
      with_env("PORTAGE_PROXY_MODE" => "gateway") do
        pc = resolve(flags: { proxy: "http://flag-proxy:3128", proxy_ca: "/tmp/ca.pem" }, config: config)
        profile = pc.chain_for(:store, host: "x").first

        expect(profile.mode).to eq(:gateway)
        expect(profile.ca_file).to eq("/tmp/ca.pem")
      end
    end
  end

  describe "proxy_headers merge (config < env < flag, per header name)" do
    let(:config) do
      cfg({ "proxy" => { "default" => { "url" => "http://p:3128",
                                        "proxy_headers" => { "X-A" => "config", "X-B" => "config" } } } })
    end

    it "later tiers override earlier ones per key, without dropping untouched keys" do
      with_env("PORTAGE_PROXY_HEADERS" => '{"X-B":"env","X-C":"env"}') do
        pc = resolve(flags: { proxy_headers: ["X-C: flag"] }, config: config)
        headers = pc.chain_for(:store, host: "x").first.proxy_headers

        expect(headers).to eq("X-A" => "config", "X-B" => "env", "X-C" => "flag")
      end
    end
  end

  describe "protected headers are refused at config-load time, from any source" do
    it "refuses Authorization via --proxy-header" do
      expect { resolve(flags: { proxy: "http://p:3128", proxy_headers: ["Authorization: Bearer x"] }) }
        .to raise_error(described_class::ConfigError, /Authorization/)
    end

    it "refuses User-Agent via PORTAGE_PROXY_HEADERS" do
      with_env("PORTAGE_PROXY_HEADERS" => '{"User-Agent":"evil"}') do
        expect { resolve(flags: { proxy: "http://p:3128" }) }.to raise_error(described_class::ConfigError, /User-Agent/)
      end
    end

    it "refuses X-Shopify-*-Access-Token via config.json's default.proxy_headers" do
      config = cfg({ "proxy" => { "default" => { "url" => "http://p:3128",
                                                 "proxy_headers" => { "X-Shopify-Admin-Access-Token" => "x" } } } })

      expect { resolve(config: config) }.to raise_error(described_class::ConfigError, /X-Shopify-Admin-Access-Token/)
    end

    it "refuses a protected header named in forward_headers.strip" do
      config = cfg({ "proxy" => { "default" => { "forward_headers" => { "strip" => ["Authorization"] } } } })

      expect { resolve(config: config) }.to raise_error(described_class::ConfigError, /Authorization/)
    end

    it "wraps the raw core exception rather than leaking it" do
      expect { resolve(flags: { proxy: "http://p:3128", proxy_headers: ["Authorization: x"] }) }
        .to raise_error(described_class::ConfigError) { |e|
          expect(e).not_to be_a(Portage::Ucp::Support::ProxyConfig::ConfigError)
        }
    end
  end

  describe "${ENV} substitution in header values" do
    it "expands config.json's default.proxy_headers values" do
      with_env("EGRESS_TOKEN" => "tok-123") do
        config = cfg({ "proxy" => { "default" => { "url" => "http://p:3128",
                                                   "proxy_headers" => { "X-Egress-Tenant" => "${EGRESS_TOKEN}" } } } })
        pc = resolve(config: config)

        expect(pc.chain_for(:store, host: "x").first.proxy_headers["X-Egress-Tenant"]).to eq("tok-123")
      end
    end

    it "expands forward_headers.add values" do
      with_env("SRC" => "agent") do
        config = cfg({ "proxy" => { "default" => { "forward_headers" =>
                                                    { "add" => { "X-Request-Source" => "${SRC}" } } } } })
        settings = described_class.new(config: config)
        settings.resolve

        expect(settings.forward_headers["add"]).to eq("X-Request-Source" => "agent")
      end
    end

    it "substitutes a missing var with an empty string" do
      config = cfg({ "proxy" => { "default" => { "url" => "http://p:3128",
                                                 "proxy_headers" => { "X-Foo" => "${NOPE_ENV_VAR}" } } } })
      pc = resolve(config: config)

      expect(pc.chain_for(:store, host: "x").first.proxy_headers["X-Foo"]).to eq("")
    end
  end

  describe "password_ref resolution" do
    it "splices the resolved secret into the profile's url" do
      allow(Portage::Cli::ProxySettings::PasswordRef).to receive(:resolve).with("egress-proxy")
                                                                          .and_return("s3cr3t")
      config = cfg({ "proxy" => { "default" => { "url" => "http://bob@egress.internal:3128",
                                                 "password_ref" => "egress-proxy" } } })

      pc = resolve(config: config)

      expect(pc.chain_for(:store, host: "x").first.url).to eq("http://bob:s3cr3t@egress.internal:3128")
    end

    it "raises a clear config error when the ref can't be resolved from any backend" do
      allow(Portage::Cli::ProxySettings::PasswordRef).to receive(:resolve).and_return(nil)
      config = cfg({ "proxy" => { "default" => { "url" => "http://bob@egress.internal:3128",
                                                 "password_ref" => "missing-ref" } } })

      expect { resolve(config: config) }.to raise_error(described_class::ConfigError, /missing-ref/)
    end
  end

  describe "--no-env-proxy" do
    it "forces the default route to :direct when nothing else is configured" do
      pc = resolve(flags: { no_env_proxy: true })

      expect(pc.configured?(:store)).to be true
      expect(pc.chain_for(:store, host: "x")).to eq([direct])
    end

    it "is a no-op once a real default proxy is configured" do
      pc = resolve(flags: { proxy: "http://p:3128", no_env_proxy: true })

      expect(pc.chain_for(:store, host: "x").first.url).to eq("http://p:3128")
    end
  end

  describe "the payment route" do
    it "defaults to direct even when a default proxy is configured" do
      pc = resolve(flags: { proxy: "http://p:3128" })

      expect(pc.chain_for(:payment, host: "x")).to eq([direct])
    end

    it "honors an explicit routes.payment = \"default\" in config.json" do
      config = cfg({ "proxy" => { "default" => { "url" => "http://p:3128" },
                                  "routes" => { "payment" => "default" } } })

      pc = resolve(config: config)

      expect(pc.chain_for(:payment, host: "x").first.url).to eq("http://p:3128")
    end

    it "honors --proxy-route payment=URL" do
      pc = resolve(flags: { proxy: "http://p:3128", proxy_routes: ["payment=http://pay-proxy:3128"] })

      expect(pc.chain_for(:payment, host: "x").first.url).to eq("http://pay-proxy:3128")
    end
  end

  describe "config.json chains" do
    it "resolves a routes.<name> = {chain: ...} reference into an ordered hop array" do
      config = cfg({ "proxy" => {
                     "chains" => { "corp-then-gateway" => [
                       { "url" => "http://corp:3128" },
                       { "mode" => "gateway", "url" => "https://gw.example/fetch", "target_header" => "X-Target-URL" }
                     ] },
                     "routes" => { "platform" => { "chain" => "corp-then-gateway" } }
                   } })

      chain = resolve(config: config).chain_for(:platform, host: "x")

      expect(chain.map(&:mode)).to eq(%i[forward gateway])
      expect(chain.last.target_header).to eq("X-Target-URL")
    end

    it "raises a clear error for an unknown chain/profile reference" do
      config = cfg({ "proxy" => { "routes" => { "search" => "no-such-chain" } } })

      expect { resolve(config: config) }.to raise_error(described_class::ConfigError, /no-such-chain/)
    end
  end

  describe "--proxy-chain" do
    it "builds an ad-hoc default chain, inferring gateway+ hops" do
      pc = resolve(flags: { proxy_chain: "http://hop1:3128,gateway+https://gw.example/fetch" })
      chain = pc.chain_for(:store, host: "x")

      expect(chain.map(&:mode)).to eq(%i[forward gateway])
      expect(chain.last.url).to eq("https://gw.example/fetch")
    end
  end

  describe "malformed config" do
    it "raises on an unparsable --proxy-route value" do
      expect { resolve(flags: { proxy_routes: ["not-a-valid-entry"] }) }.to raise_error(described_class::ConfigError)
    end

    it "raises on invalid PORTAGE_PROXY_HEADERS JSON" do
      with_env("PORTAGE_PROXY_HEADERS" => "{not json") do
        expect { resolve(flags: { proxy: "http://p:3128" }) }
          .to raise_error(described_class::ConfigError, /PORTAGE_PROXY_HEADERS/)
      end
    end

    it "raises on a --proxy-header with no colon" do
      expect { resolve(flags: { proxy: "http://p:3128", proxy_headers: ["garbage"] }) }
        .to raise_error(described_class::ConfigError)
    end
  end

  describe "no_proxy precedence" do
    let(:config) { cfg({ "proxy" => { "default" => { "no_proxy" => ["config.example"] } } }) }

    it "a flag replaces the whole list" do
      expect(resolve(flags: { no_proxy: "a.example,b.example" }, config: config).no_proxy)
        .to eq(%w[a.example b.example])
    end

    it "env replaces it when no flag is given" do
      with_env("PORTAGE_NO_PROXY" => "env.example") do
        expect(resolve(config: config).no_proxy).to eq(["env.example"])
      end
    end
  end
end
