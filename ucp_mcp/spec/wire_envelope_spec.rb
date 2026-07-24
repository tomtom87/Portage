require "spec_helper"

RSpec.describe UcpMcp::WireEnvelope do
  it "adds a minimal version envelope to a cart payload" do
    wrapped = described_class.wrap("dev.ucp.shopping.cart", { "id" => "cart_1" })
    expect(wrapped["ucp"]).to eq({ "version" => "2026-04-08" })
  end

  it "adds version + payment_handlers to a checkout payload (required by response_checkout_schema)" do
    wrapped = described_class.wrap("dev.ucp.shopping.checkout", { "id" => "chk_1" })
    expect(wrapped["ucp"]).to eq({ "version" => "2026-04-08", "payment_handlers" => {} })
  end

  it "adds a minimal version envelope to an order payload" do
    wrapped = described_class.wrap("dev.ucp.shopping.order", { "id" => "ord_1" })
    expect(wrapped["ucp"]).to eq({ "version" => "2026-04-08" })
  end

  it "leaves payloads for capabilities with no known envelope untouched" do
    payload = { "id" => "prod_1" }
    expect(described_class.wrap("dev.ucp.shopping.catalog", payload)).to equal(payload)
  end
end
