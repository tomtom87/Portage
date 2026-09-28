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

    it "derives capabilities from the page's tools when none are given" do
      bridge = FakeBridge.new.register("search_catalog").register("create_cart")

      session = described_class.connect(bridge: bridge)

      expect(session.advertises?("dev.ucp.shopping.cart")).to be(true)
      expect(session.advertises?("dev.ucp.shopping.checkout")).to be(false)
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

  describe "preset: (Phase 1, docs/plans/webmcp-universal-outbound.md)" do
    def shopify_bridge
      FakeBridge.new.register("search_catalog").register("add_to_cart").register("get_product")
                .register("get_cart").register("cancel_cart").register("update_cart_lines")
                .register("proceed_to_checkout")
    end

    it "auto-detects a known preset and applies its tool_names:/wire: (the default)" do
      session = described_class.connect(bridge: shopify_bridge)

      expect(session.get_product(product_id: "p1")).to eq({})
      expect(session.advertises?("dev.ucp.shopping.cart")).to be(true)
      expect(session.advertises?("dev.ucp.shopping.checkout")).to be(true)
    end

    it "leaves an unrecognized page alone under preset: :auto (the default before Phase 1 existed)" do
      bridge = FakeBridge.new.register("search_catalog")

      expect { described_class.connect(bridge: bridge).create_cart(line_items: []) }
        .to raise_error(described_class::ToolNotFoundError)
    end

    it "turns presets off with preset: nil, even against a page a preset would otherwise match" do
      session = described_class.connect(bridge: shopify_bridge, preset: nil)

      expect { session.create_cart(line_items: []) }.to raise_error(described_class::ToolNotFoundError, /add_to_cart/)
    end

    it "forces a named preset with no extra page read to detect one (only capabilities: nil's own read)" do
      bridge = FakeBridge.new.register("add_to_cart")
      session = described_class.connect(bridge: bridge, preset: :shopify)

      expect(bridge.list_count).to eq(1)
      expect { session.create_cart(line_items: []) }.not_to raise_error
    end

    it "lets an explicit tool_names: win over the preset's own, key by key" do
      bridge = FakeBridge.new.register("add_to_bag").register("get_product")
      session = described_class.connect(bridge: bridge, preset: :shopify, tool_names: { create_cart: "add_to_bag" })

      expect { session.create_cart(line_items: []) }.not_to raise_error
    end
  end

  it "rescues under the client's own error hierarchy" do
    expect(described_class::BridgeError.ancestors).to include(Portage::Ucp::Client::Error)
    expect(described_class::ToolNotFoundError.ancestors).to include(Portage::Ucp::Client::Error)
  end
end
