require "spec_helper"
require "portage/ucp/rspec"

# Design-log §17: runs the shipped conformance kit against the real Magento
# Adapter through a real Dispatcher. Discount/fulfillment/identity examples
# self-skip — Magento advertises catalog/cart/checkout/order only.
RSpec.describe Portage::Ucp::Magento::Adapter do
  let(:client) { Portage::Ucp::Magento::Client.new(base_url: "https://shop.example.com", admin_token: "admin-tok") }
  let(:default_address) do
    { firstname: "Ada", lastname: "Lovelace", street: ["1 Main St"], city: "Boston", region: "MA",
      postcode: "02110", country_id: "US", telephone: "555-0100", email: "ada@example.com" }
  end
  let(:adapter) do
    described_class.new(client: client, currency: "USD", site_url: "https://shop.example.com",
                        payment_method: "checkmo", default_address: default_address)
  end
  let(:existing_product_id) { "cold-brew" }

  # #create_checkout mints a guest cart, adds items, then snapshots
  # items+totals — and the kit reaches nothing further: the repeat call is
  # served by Support::Idempotency's in-process table, and the PAN example is
  # rejected by PaymentTokenGuard inside the Dispatcher before
  # #complete_checkout (and so before shipping/payment-information) runs.
  before do
    stub_request(:post, "https://shop.example.com/rest/V1/guest-carts").to_return(status: 200, body: '"cart_1"')
    stub_request(:post, "https://shop.example.com/rest/V1/guest-carts/cart_1/items")
      .to_return(status: 200, body: { item_id: 1 }.to_json)
    stub_request(:get, "https://shop.example.com/rest/V1/guest-carts/cart_1/items")
      .to_return(status: 200, body: [{ "item_id" => 1, "sku" => "cold-brew", "name" => "Cold Brew",
                                       "qty" => 1, "price" => 5.0 }].to_json)
    stub_request(:get, "https://shop.example.com/rest/V1/guest-carts/cart_1/totals")
      .to_return(status: 200, body: { "quote_currency_code" => "USD",
                                      "items" => [{ "item_id" => 1, "row_total" => "5.0000",
                                                    "tax_amount" => "0.0000" }] }.to_json)
  end

  it_behaves_like "a portage adapter"
end
