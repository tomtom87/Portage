require "spec_helper"

RSpec.describe Portage::Ucp::Capability do
  let(:capability) do
    described_class.new(
      name: "dev.ucp.shopping.catalog",
      version: "1",
      actions: { "search_catalog" => :search_catalog, "get_product" => :get_product }
    )
  end

  it "is not advertised for a plain Adapter (no methods overridden)" do
    expect(capability.advertised_for?(Portage::Ucp::Adapter.new)).to eq(false)
  end

  it "is advertised once any one of its backing methods is overridden" do
    partial = Class.new(Portage::Ucp::Adapter) do
      def search_catalog(query:, limit:) = []
    end.new
    expect(capability.advertised_for?(partial)).to eq(true)
  end

  it "is advertised when all backing methods are overridden" do
    full = Class.new(Portage::Ucp::Adapter) do
      def search_catalog(query:, limit:) = []
      def get_product(product_id:) = nil
    end.new
    expect(capability.advertised_for?(full)).to eq(true)
  end

  describe "predicate-based advertisement (extension capabilities with no actions of their own)" do
    let(:predicated) do
      described_class.new(name: "dev.ucp.shopping.discount", version: "1", actions: {},
                          predicate: :discount_codes_supported?)
    end

    it "is not advertised when the adapter's predicate returns false" do
      expect(predicated.advertised_for?(Portage::Ucp::Adapter.new)).to eq(false)
    end

    it "is advertised when the adapter's predicate returns true" do
      supported = Class.new(Portage::Ucp::Adapter) do
        def discount_codes_supported? = true
      end.new
      expect(predicated.advertised_for?(supported)).to eq(true)
    end
  end
end
