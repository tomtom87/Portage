require "spec_helper"

RSpec.describe Portage::Ucp::WebMcp do
  it "has a version" do
    expect(described_class::VERSION).to match(/\A\d+\.\d+\.\d+\z/)
  end

  describe ".connect" do
    it "returns a client Session over the WebMCP transport" do
      session = described_class.connect(bridge: FakeBridge.new, capabilities: ["dev.ucp.shopping.catalog"])

      expect(session).to be_a(Portage::Ucp::Client::Session)
      expect(session.advertises?("dev.ucp.shopping.catalog")).to be(true)
    end

    it "builds the ScriptEvaluator bridge from evaluate:" do
      session = described_class.connect(evaluate: ->(_) { '{"ok":true,"value":[]}' })
      transport = session.instance_variable_get(:@transport)

      expect(transport.bridge).to be_a(described_class::Bridges::ScriptEvaluator)
    end

    it "forwards transport options" do
      bridge = FakeBridge.new.register("acme.get_cart") { { "id" => "c1" } }

      expect(described_class.connect(bridge: bridge, prefix: "acme.").get_cart(cart_id: "c1")).to eq("id" => "c1")
    end

    it "requires a bridge or evaluate:" do
      expect { described_class.connect }.to raise_error(ArgumentError, /bridge: or evaluate:/)
    end
  end

  it "rescues under the client's own error hierarchy" do
    expect(described_class::BridgeError.ancestors).to include(Portage::Ucp::Client::Error)
    expect(described_class::ToolNotFoundError.ancestors).to include(Portage::Ucp::Client::Error)
  end
end
