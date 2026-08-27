require "spec_helper"

RSpec.describe Portage::Ucp::CapabilityRegistry do
  let(:catalog_capability) do
    Portage::Ucp::Capability.new(name: "dev.ucp.shopping.catalog", version: "1",
                                 actions: { "search_catalog" => :search_catalog })
  end
  let(:cart_capability) do
    Portage::Ucp::Capability.new(name: "dev.ucp.shopping.cart", version: "1",
                                 actions: { "get_cart" => :get_cart })
  end
  let(:registry) { described_class.new(capabilities: [catalog_capability, cart_capability]) }

  it "advertises only capabilities whose adapter methods are overridden" do
    catalog_only = Class.new(Portage::Ucp::Adapter) do
      def search_catalog(query:, limit:) = []
    end.new

    expect(registry.advertised(catalog_only)).to eq([catalog_capability])
  end

  it "advertises nothing for a plain, unconfigured Adapter" do
    expect(registry.advertised(Portage::Ucp::Adapter.new)).to eq([])
  end

  it "finds a registered capability by name" do
    expect(registry.find("dev.ucp.shopping.cart")).to eq(cart_capability)
  end

  it "returns nil for an unregistered capability name" do
    expect(registry.find("dev.ucp.shopping.nonexistent")).to be_nil
  end

  describe ".default" do
    it "includes the built-in catalog/cart/checkout/order/discount/fulfillment/identity/reorder capabilities" do
      names = described_class.default.instance_variable_get(:@capabilities).map(&:name)
      expect(names).to contain_exactly(
        "dev.ucp.shopping.catalog",
        "dev.ucp.shopping.cart",
        "dev.ucp.shopping.checkout",
        "dev.ucp.shopping.order",
        "dev.ucp.shopping.discount",
        "dev.ucp.shopping.fulfillment",
        "dev.ucp.shopping.identity",
        "app.portage-ucp.reorder"
      )
    end
  end
end
