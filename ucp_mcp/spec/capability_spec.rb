require "spec_helper"

RSpec.describe UcpMcp::Capability do
  let(:capability) do
    described_class.new(
      name: "dev.ucp.shopping.catalog",
      version: "1",
      actions: { "search_catalog" => :search_catalog, "get_product" => :get_product }
    )
  end

  it "is not advertised for a plain Adapter (no methods overridden)" do
    expect(capability.advertised_for?(UcpMcp::Adapter.new)).to eq(false)
  end

  it "is advertised once any one of its backing methods is overridden" do
    partial = Class.new(UcpMcp::Adapter) do
      def search_catalog(query:, limit:) = []
    end.new
    expect(capability.advertised_for?(partial)).to eq(true)
  end

  it "is advertised when all backing methods are overridden" do
    full = Class.new(UcpMcp::Adapter) do
      def search_catalog(query:, limit:) = []
      def get_product(product_id:) = nil
    end.new
    expect(capability.advertised_for?(full)).to eq(true)
  end
end
