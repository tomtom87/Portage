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
        .with(url: "https://shop.example/mcp", headers: {}).and_return(transport)

      session = described_class.connect(url: "https://shop.example/mcp")

      expect(session.instance_variable_get(:@transport)).to equal(transport)
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
        .with(url: "https://shop.example/mcp", headers: {}).and_return(transport)

      session = described_class.discover("https://shop.example")

      expect(session.capabilities).to eq(["dev.ucp.shopping.catalog"])
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

    it "raises DiscoveryError when the manifest has no mcp service entry" do
      stub_request(:get, "https://shop.example/.well-known/ucp").to_return(
        status: 200, body: { services: [{ transport: "rest", endpoint: "https://shop.example/rest" }] }.to_json
      )

      expect { described_class.discover("https://shop.example") }
        .to raise_error(Portage::Ucp::Client::DiscoveryError, /no mcp service/)
    end
  end
end
