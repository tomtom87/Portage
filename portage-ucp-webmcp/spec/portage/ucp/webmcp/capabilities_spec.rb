require "spec_helper"

RSpec.describe Portage::Ucp::WebMcp::Capabilities do
  def capabilities_for(bridge, **options)
    described_class.for(Portage::Ucp::WebMcp::Transport.new(bridge: bridge, **options))
  end

  it "counts a capability when the page answers the action that starts it" do
    bridge = FakeBridge.new.register("search_catalog").register("create_cart").register("create_checkout")

    expect(capabilities_for(bridge)).to eq(%w[dev.ucp.shopping.catalog dev.ucp.shopping.cart
                                              dev.ucp.shopping.checkout])
  end

  it "counts no capability for tools that only continue one" do
    bridge = FakeBridge.new.register("get_cart").register("update_checkout")

    expect(capabilities_for(bridge)).to eq([])
  end

  it "resolves names through tool_names: and prefix:, the way a call does" do
    bridge = FakeBridge.new.register("add_to_cart").register("acme.get_product")

    expect(capabilities_for(bridge, tool_names: { create_cart: "add_to_cart" }, prefix: "acme."))
      .to eq(%w[dev.ucp.shopping.catalog dev.ucp.shopping.cart])
  end

  it "reads the page once" do
    bridge = FakeBridge.new.register("search_catalog")

    capabilities_for(bridge)

    expect(bridge.list_count).to eq(1)
  end
end
