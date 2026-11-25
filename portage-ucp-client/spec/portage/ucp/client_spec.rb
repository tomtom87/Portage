require "spec_helper"
require "support/fake_adapter"

RSpec.describe Portage::Ucp::Client do
  describe ".for_adapter" do
    it "returns a Session wrapping a loopback transport" do
      session = described_class.for_adapter(Portage::Ucp::Client::Support::FakeAdapter.new)

      expect(session).to be_a(Portage::Ucp::Client::Session)
      expect(session.instance_variable_get(:@transport)).to be_a(Portage::Ucp::Client::Transports::Loopback)
    end
  end

  describe ".connect" do
    it "raises ArgumentError when neither command: nor url: is given" do
      expect { described_class.connect }.to raise_error(ArgumentError, /command:.*url:/)
    end

    it "builds a stdio transport when command: is given" do
      transport = instance_double(Portage::Ucp::Client::Transports::Stdio)
      allow(Portage::Ucp::Client::Transports::Stdio).to receive(:new)
        .with(command: "portage-ucp-server", args: [], env: nil).and_return(transport)

      session = described_class.connect(command: "portage-ucp-server")

      expect(session.instance_variable_get(:@transport)).to equal(transport)
    end

    it "builds an HTTP transport when url: is given" do
      transport = instance_double(Portage::Ucp::Client::Transports::Http)
      allow(Portage::Ucp::Client::Transports::Http).to receive(:new)
        .with(url: "https://shop.example/mcp", headers: {}, proxy: nil).and_return(transport)

      session = described_class.connect(url: "https://shop.example/mcp")

      expect(session.instance_variable_get(:@transport)).to equal(transport)
    end

    it "threads proxy: through to the HTTP transport (docs/plans/proxy-support.md Phase 1)" do
      transport = instance_double(Portage::Ucp::Client::Transports::Http)
      allow(Portage::Ucp::Client::Transports::Http).to receive(:new)
        .with(url: "https://shop.example/mcp", headers: {}, proxy: "http://proxy.example:3128").and_return(transport)

      described_class.connect(url: "https://shop.example/mcp", proxy: "http://proxy.example:3128")

      expect(Portage::Ucp::Client::Transports::Http).to have_received(:new)
        .with(url: "https://shop.example/mcp", headers: {}, proxy: "http://proxy.example:3128")
    end
  end

  describe ".connect transport:" do
    it "builds a REST session for transport: :rest" do
      transport = instance_double(Portage::Ucp::Client::Transports::Rest)
      allow(Portage::Ucp::Client::Transports::Rest).to receive(:new)
        .with(url: "https://shop.example/ucp", headers: { "X" => "y" }, proxy: nil).and_return(transport)

      session = described_class.connect(url: "https://shop.example/ucp", headers: { "X" => "y" }, transport: :rest)

      expect(session.transport_name).to eq(:rest)
    end

    it "defaults to :mcp and rejects unknown transports" do
      allow(Portage::Ucp::Client::Transports::Http).to receive(:new)
        .and_return(instance_double(Portage::Ucp::Client::Transports::Http))

      expect(described_class.connect(url: "https://shop.example/mcp").transport_name).to eq(:mcp)
      expect { described_class.connect(url: "https://shop.example", transport: :a2a) }
        .to raise_error(ArgumentError, /transport must be :mcp or :rest/)
    end
  end

  describe ".discover" do
    it "fetches the manifest, connects to its mcp service endpoint, and scopes capabilities" do
      stub_request(:get, "https://shop.example/.well-known/ucp").to_return(
        status: 200,
        body: {
          services: [{ transport: "mcp", endpoint: "https://shop.example/mcp" }],
          capabilities: [{ name: "dev.ucp.shopping.catalog", version: "1" }]
        }.to_json
      )
      transport = instance_double(Portage::Ucp::Client::Transports::Http)
      allow(Portage::Ucp::Client::Transports::Http).to receive(:new)
        .with(url: "https://shop.example/mcp", headers: {}, proxy: nil).and_return(transport)

      session = described_class.discover("https://shop.example")

      expect(session.capabilities).to eq(["dev.ucp.shopping.catalog"])
    end

    let(:mcp_manifest) { { services: [{ transport: "mcp", endpoint: "https://shop.example/mcp" }] }.to_json }

    it "identifies itself as Portage on the manifest GET" do
      stub_request(:get, "https://shop.example/.well-known/ucp")
        .with(headers: { "User-Agent" => Portage::Ucp::Client::USER_AGENT })
        .to_return(status: 200, body: mcp_manifest)
      allow(Portage::Ucp::Client::Transports::Http).to receive(:new)

      described_class.discover("https://shop.example")

      expect(Portage::Ucp::Client::USER_AGENT).to match(%r{\Aportage-ucp-client/\d+\.\d+\.\d+ \(\+https://})
    end

    it "sends the caller's headers, its own User-Agent included, on the GET and every call after it" do
      headers = { "User-Agent" => "portage-cli/1.0" }
      stub_request(:get, "https://shop.example/.well-known/ucp").with(headers: headers)
                                                                .to_return(status: 200, body: mcp_manifest)
      allow(Portage::Ucp::Client::Transports::Http).to receive(:new)

      described_class.discover("https://shop.example", headers: headers)

      expect(Portage::Ucp::Client::Transports::Http).to have_received(:new)
        .with(url: "https://shop.example/mcp", headers: headers, proxy: nil)
    end

    it "raises DiscoveryError when the manifest can't be fetched" do
      stub_request(:get, "https://shop.example/.well-known/ucp").to_return(status: 404)

      expect { described_class.discover("https://shop.example") }
        .to raise_error(Portage::Ucp::Client::DiscoveryError, /404/)
    end

    it "raises DiscoveryError, not a raw network exception, when the host can't be reached" do
      stub_request(:get, "https://shop.example/.well-known/ucp").to_raise(SocketError.new("getaddrinfo failed"))

      expect { described_class.discover("https://shop.example") }
        .to raise_error(Portage::Ucp::Client::DiscoveryError, /couldn't reach/)
    end

    it "falls back to the rest service entry when the manifest has no mcp one" do
      stub_request(:get, "https://shop.example/.well-known/ucp").to_return(
        status: 200, body: { services: [{ transport: "rest", endpoint: "https://shop.example/rest" }] }.to_json
      )
      transport = instance_double(Portage::Ucp::Client::Transports::Rest)
      allow(Portage::Ucp::Client::Transports::Rest).to receive(:new)
        .with(url: "https://shop.example/rest", headers: {}, proxy: nil).and_return(transport)

      expect(described_class.discover("https://shop.example").transport_name).to eq(:rest)
    end

    describe "the dev.ucp.common service (ask)" do
      let(:shopping) { { "transport" => "mcp", "endpoint" => "https://shop.example/mcp" } }
      let(:mcp_session) { instance_double(Portage::Ucp::Client::Session) }
      let(:ask_result) { { "answer" => { "plain" => "ok" } } }

      def manifest_with(services)
        stub_request(:get, "https://shop.example/.well-known/ucp").to_return(
          status: 200,
          body: { ucp: { services: services, capabilities: { "dev.ucp.common.ask" => [{}] } } }.to_json
        )
      end

      def stub_ask(transport_class, url, wire)
        allow(transport_class).to receive(:new).with(url: url, headers: {}, proxy: nil).and_return(wire)
        allow(wire).to receive(:call_tool).and_return(ask_result)
      end

      let(:meta) { { agent_profile: "https://agent.example/profile" } }

      it "uses the one transport when common shares the shopping endpoint" do
        manifest_with("dev.ucp.shopping" => [shopping], "dev.ucp.common" => [shopping])
        wire = instance_double(Portage::Ucp::Client::Transports::Http)
        stub_ask(Portage::Ucp::Client::Transports::Http, "https://shop.example/mcp", wire)

        session = described_class.discover("https://shop.example")

        expect(session.ask(query: "q", meta: meta)).to eq(ask_result)
        expect(Portage::Ucp::Client::Transports::Http).to have_received(:new).once
        expect(wire).to have_received(:call_tool).with(name: "ask_business", arguments: { query: "q" }, meta: meta)
      end

      it "sends ask to the common endpoint, over its own transport, when it differs" do
        common = { "transport" => "rest", "endpoint" => "https://common.example/ucp" }
        manifest_with("dev.ucp.shopping" => [shopping], "dev.ucp.common" => [common])
        main = instance_double(Portage::Ucp::Client::Transports::Http, call_tool: {})
        rest = instance_double(Portage::Ucp::Client::Transports::Rest)
        stub_ask(Portage::Ucp::Client::Transports::Http, "https://shop.example/mcp", main)
        stub_ask(Portage::Ucp::Client::Transports::Rest, "https://common.example/ucp", rest)

        session = described_class.discover("https://shop.example")

        expect(Portage::Ucp::Client::Transports::Rest).not_to have_received(:new)
        expect(session.ask(query: "q", meta: meta)).to eq(ask_result)
        expect(rest).to have_received(:call_tool).with(name: "ask_business", arguments: { query: "q" }, meta: meta)
        expect(main).not_to have_received(:call_tool)
      end

      # Some stores list ask without a dev.ucp.common service entry; the
      # shopping endpoint is the only place to send it.
      it "falls back to the shopping endpoint when the manifest has no common service" do
        manifest_with("dev.ucp.shopping" => [shopping])
        wire = instance_double(Portage::Ucp::Client::Transports::Http)
        stub_ask(Portage::Ucp::Client::Transports::Http, "https://shop.example/mcp", wire)

        session = described_class.discover("https://shop.example")

        expect(session.advertises?("dev.ucp.common.ask")).to be(true)
        expect(session.ask(query: "q", meta: meta)).to eq(ask_result)
        expect(Portage::Ucp::Client::Transports::Http).to have_received(:new).once
      end
    end

    it "discovers the #178 REST-only sandbox manifest over REST" do
      stub_request(:get, "https://shop.example/.well-known/ucp").to_return(
        status: 200, body: File.read(File.expand_path("../../fixtures/rest_only_manifest.json", __dir__))
      )
      endpoint = "https://agent-gateway-partner-sandbox.onrender.com/ucp/2026-08-25"
      allow(Portage::Ucp::Client::Transports::Rest).to receive(:new)
        .with(url: endpoint, headers: {}, proxy: nil)
        .and_return(instance_double(Portage::Ucp::Client::Transports::Rest))

      session = described_class.discover("https://shop.example")

      expect(session.transport_name).to eq(:rest)
      expect(session.capabilities).to eq(["dev.ucp.shopping.checkout"])
    end

    it "prefers mcp over rest when a store offers both" do
      stub_request(:get, "https://shop.example/.well-known/ucp").to_return(
        status: 200,
        body: { services: [{ transport: "rest", endpoint: "https://shop.example/rest" },
                           { transport: "mcp", endpoint: "https://shop.example/mcp" }] }.to_json
      )
      allow(Portage::Ucp::Client::Transports::Http).to receive(:new)
        .with(url: "https://shop.example/mcp", headers: {}, proxy: nil)
        .and_return(instance_double(Portage::Ucp::Client::Transports::Http))

      expect(described_class.discover("https://shop.example").transport_name).to eq(:mcp)
    end

    it "raises ManifestShapeError listing the transports it saw when there is no mcp or rest entry" do
      stub_request(:get, "https://shop.example/.well-known/ucp").to_return(
        status: 200,
        body: { services: [{ transport: "a2a", endpoint: "https://shop.example/a2a" },
                           { transport: "embedded" }] }.to_json
      )

      expect { described_class.discover("https://shop.example") }
        .to raise_error(Portage::Ucp::Client::ManifestShapeError,
                        "manifest has no mcp or rest service entry to connect to (saw: a2a, embedded)")
    end

    # Real shape served by live Shopify UCP rollouts (Casper, Allbirds,
    # Glossier, and 34+ others) as of manifest "version": "2026-08-25" —
    # everything nested under "ucp", services/capabilities as hashes keyed by
    # name rather than flat arrays.
    it "parses the nested hash-of-arrays manifest shape real stores serve" do
      stub_request(:get, "https://shop.example/.well-known/ucp").to_return(
        status: 200,
        body: {
          ucp: {
            version: "2026-08-25",
            services: {
              "dev.ucp.shopping" => [
                { version: "2026-08-25", transport: "mcp", endpoint: "https://shop.example/api/ucp/mcp" },
                { version: "2026-04-08", transport: "embedded" }
              ]
            },
            capabilities: {
              "dev.ucp.shopping.checkout" => [{ version: "2026-08-25" }],
              "dev.ucp.shopping.cart" => [{ version: "2026-08-25" }]
            }
          }
        }.to_json
      )
      transport = instance_double(Portage::Ucp::Client::Transports::Http)
      allow(Portage::Ucp::Client::Transports::Http).to receive(:new)
        .with(url: "https://shop.example/api/ucp/mcp", headers: {}, proxy: nil).and_return(transport)

      session = described_class.discover("https://shop.example")

      expect(session.capabilities).to contain_exactly("dev.ucp.shopping.checkout", "dev.ucp.shopping.cart")
    end

    # What portage-ucp emitted before 2026-08-25: nested under "ucp" but with
    # `services` still a bare array of entries.
    it "parses a nested manifest whose services is still the old bare array" do
      stub_request(:get, "https://shop.example/.well-known/ucp").to_return(
        status: 200,
        body: {
          ucp: {
            version: "2026-04-08",
            services: [{ transport: "mcp", endpoint: "https://shop.example/mcp" }],
            capabilities: { "dev.ucp.shopping.cart" => [{ version: "1" }] }
          }
        }.to_json
      )
      allow(Portage::Ucp::Client::Transports::Http).to receive(:new)
        .with(url: "https://shop.example/mcp", headers: {}, proxy: nil)
        .and_return(instance_double(Portage::Ucp::Client::Transports::Http))

      expect(described_class.discover("https://shop.example").capabilities).to eq(["dev.ucp.shopping.cart"])
    end
  end
end
