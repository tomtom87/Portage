require "spec_helper"
require "portage/ucp/rspec"
require "support/product_factory"

# Runs the conformance kit against the gem's own ReferenceAdapter — proves
# both that the shipped reference implementation actually satisfies the
# contract, and that the kit itself (portage/ucp/rspec.rb) is wired up
# correctly, before any third-party adapter gem depends on it.
RSpec.describe Portage::Ucp::ReferenceAdapter do
  let(:adapter) { described_class.new }
  let(:existing_product_id) { "prod_1" }
  let(:out_of_stock_product_id) { "oos_1" }

  before do
    adapter.seed_product(ProductFactory.build(id: "prod_1", title: "Cold Brew", price_minor: 500))
    adapter.seed_product(ProductFactory.build(id: "oos_1", title: "Sold Out Blend", price_minor: 700,
                                              available: false))
  end

  it_behaves_like "a portage adapter"

  it "advertises discount and fulfillment (both true) and identity (link_identity overridden)" do
    registry = Portage::Ucp::CapabilityRegistry.default
    advertised = registry.advertised(adapter).map(&:name)

    expect(advertised).to include("dev.ucp.shopping.discount", "dev.ucp.shopping.fulfillment",
                                  "dev.ucp.shopping.identity")
  end

  it "links an oauth token to a stable identity" do
    first = adapter.link_identity(oauth_token: "tok_abc")
    second = adapter.link_identity(oauth_token: "tok_abc")

    expect(first).to eq(second)
    expect(first.subject).to match(/\Auser_[0-9a-f]{12}\z/)
  end
end
