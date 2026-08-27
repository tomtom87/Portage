require "spec_helper"
require "portage/ucp/rspec"

# Runs the conformance kit against the gem's own ReferenceAdapter — proves
# both that the shipped reference implementation actually satisfies the
# contract, and that the kit itself (portage/ucp/rspec.rb) is wired up
# correctly, before any third-party adapter gem depends on it.
RSpec.describe Portage::Ucp::ReferenceAdapter do
  let(:adapter) { described_class.new }
  let(:existing_product_id) { "prod_1" }
  let(:out_of_stock_product_id) { "oos_1" }

  before do
    adapter.seed_product(
      Portage::Ucp::Product.new(id: "prod_1", title: "Cold Brew", description: "desc",
                                price: Portage::Ucp::Money.new(amount_minor: 500, currency: "USD"),
                                available: true, variants: [], url: "https://example.com/prod_1")
    )
    adapter.seed_product(
      Portage::Ucp::Product.new(id: "oos_1", title: "Sold Out Blend", description: "desc",
                                price: Portage::Ucp::Money.new(amount_minor: 700, currency: "USD"),
                                available: false, variants: [], url: "https://example.com/oos_1")
    )
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
