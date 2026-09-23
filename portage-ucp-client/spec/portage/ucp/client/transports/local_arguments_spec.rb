require "spec_helper"

RSpec.describe Portage::Ucp::Client::Transports::LocalArguments do
  it "drops the real-UCP wire arguments an Adapter signature doesn't take" do
    arguments = { line_items: [], idempotency_key: "k", context: { currency: "USD" }, cart_id: "c1",
                  handler_id: "dev.shopify.card", credential_type: "t" }

    expect(described_class.strip("create_checkout", arguments)).to eq(line_items: [], idempotency_key: "k")
  end

  it "keeps cart_id where it is the Adapter's own keyword rather than a wire concern" do
    %w[get_cart update_cart cancel_cart].each do |action|
      expect(described_class.strip(action, { cart_id: "c1", context: { currency: "USD" } })).to eq(cart_id: "c1")
    end
  end
end
