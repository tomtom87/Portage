require "spec_helper"
require "support/fake_adapter"

RSpec.describe UcpMcp::CapabilityNegotiator do
  let(:adapter) { UcpMcp::Support::FakeAdapter.new }
  let(:negotiator) { described_class.new }

  it "negotiates the business-advertised version when the platform offers it" do
    result = negotiator.negotiate(adapter: adapter, platform_versions: { "dev.ucp.shopping.catalog" => ["1"] })

    expect(result["dev.ucp.shopping.catalog"]).to eq("1")
  end

  it "falls back to the business-advertised version when the platform advertises nothing (stdio, §10)" do
    result = negotiator.negotiate(adapter: adapter, platform_versions: {})

    expect(result["dev.ucp.shopping.cart"]).to eq("1")
  end

  it "omits a capability when there is no version in common" do
    result = negotiator.negotiate(adapter: adapter, platform_versions: { "dev.ucp.shopping.catalog" => ["2"] })

    expect(result).not_to have_key("dev.ucp.shopping.catalog")
  end

  it "only negotiates capabilities the adapter actually advertises" do
    result = negotiator.negotiate(adapter: adapter, platform_versions: {})

    expect(result.keys).not_to include("dev.ucp.shopping.order", "dev.ucp.shopping.identity")
  end
end
