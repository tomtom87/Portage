require "spec_helper"
require "portage/ucp/rspec"

# Design-log §17: runs the shipped conformance kit against the real
# WooCommerce Adapter through a real Dispatcher. Discount/fulfillment/identity
# examples self-skip — WooCommerce advertises catalog/cart/checkout/order only.
RSpec.describe Portage::Ucp::WooCommerce::Adapter do
  let(:client) do
    Portage::Ucp::WooCommerce::Client.new(site_url: "https://shop.example.com", consumer_key: "ck",
                                          consumer_secret: "cs")
  end
  let(:adapter) do
    described_class.new(client: client, site_url: "https://shop.example.com", currency: "USD",
                        payment_method: "stripe_cc")
  end
  let(:existing_product_id) { 1 }

  let(:cart_response) do
    { "items" => [{ "key" => "line_1", "id" => 1, "name" => "Cold Brew", "quantity" => 1,
                    "prices" => { "price" => "500" } }],
      "totals" => { "currency_code" => "USD", "total_items" => "500", "total_tax" => "0",
                    "total_price" => "500" } }
  end

  # Woo's #create_checkout replaces cart lines, so the kit reaches the cart
  # read plus add-item and nothing further: the repeat call is served by
  # Support::Idempotency's in-process table, and the PAN example is rejected by
  # PaymentTokenGuard inside the Dispatcher before #complete_checkout (and so
  # before the Store API checkout POST) runs.
  before do
    stub_request(:get, "https://shop.example.com/wp-json/wc/store/v1/cart")
      .to_return(status: 200, body: cart_response.merge("items" => []).to_json,
                 headers: { "Cart-Token" => "tok_1" })
    stub_request(:post, "https://shop.example.com/wp-json/wc/store/v1/cart/add-item")
      .to_return(status: 200, body: cart_response.to_json, headers: { "Cart-Token" => "tok_1" })
  end

  it_behaves_like "a portage adapter"
end
