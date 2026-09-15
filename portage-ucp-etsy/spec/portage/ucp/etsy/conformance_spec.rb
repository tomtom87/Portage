require "spec_helper"
require "portage/ucp/rspec"

# Design-log §17: runs the shipped conformance kit against the real Etsy
# Adapter through a real Dispatcher. Etsy advertises catalog/checkout/order
# and no cart, so the cart-shaped examples never apply; the checkout ones do
# run, because #create_checkout/#get_checkout are overridden even though
# Etsy's checkout is a redirect link rather than a completable transaction
# (§16) — which is exactly the case §17 wanted checked rather than assumed.
RSpec.describe Portage::Ucp::Etsy::Adapter do
  let(:client) { Portage::Ucp::Etsy::Client.new(access_token: "acc-tok", api_key: "keystring") }
  let(:adapter) { described_class.new(client: client, shop_id: "shop_1") }
  let(:existing_product_id) { 1 }

  let(:listing_node) do
    { "listing_id" => 1, "title" => "Handmade Mug", "description" => "desc",
      "price" => { "amount" => 2500, "divisor" => 100, "currency_code" => "USD" },
      "quantity" => 5, "state" => "active",
      "url" => "https://www.etsy.com/listing/1/handmade-mug" }
  end

  # The listing fetch is the only network call the kit reaches for checkout:
  # the repeat call is served by Support::Idempotency's in-process table, and
  # the PAN example is rejected by PaymentTokenGuard inside the Dispatcher —
  # so Etsy's #complete_checkout NotImplementedError is never what makes it
  # pass. The catalog reads are hit directly by the kit's own
  # schema-validation examples.
  before do
    stub_request(:get, "https://api.etsy.com/v3/application/listings/1")
      .to_return(status: 200, body: listing_node.to_json)
    stub_request(:get, "https://api.etsy.com/v3/application/listings/1/inventory")
      .to_return(status: 200, body: { "products" => [
        { "product_id" => 10, "is_deleted" => false, "property_values" => [{ "values" => ["Red"] }],
          "offerings" => [{ "is_enabled" => true, "quantity" => 3,
                            "price" => { "amount" => 2500, "divisor" => 100, "currency_code" => "USD" } }] }
      ] }.to_json)
    stub_request(:get, "https://api.etsy.com/v3/application/shops/shop_1/listings/active?limit=100")
      .to_return(status: 200, body: { "results" => [listing_node] }.to_json)
  end

  it_behaves_like "a portage adapter"
end
