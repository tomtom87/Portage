require "spec_helper"
require "portage/ucp/rspec"

# Design-log §17: runs the shipped conformance kit against the real
# BigCommerce Adapter through a real Dispatcher. Discount/fulfillment/identity
# examples self-skip — BigCommerce advertises catalog/cart/checkout/order only.
RSpec.describe Portage::Ucp::BigCommerce::Adapter do
  let(:client) do
    Portage::Ucp::BigCommerce::Client.new(store_hash: "abc123", client_id: "client_1", access_token: "token_1")
  end
  let(:adapter) do
    described_class.new(client: client, site_url: "https://shop.example.com", currency: "USD",
                        payment_gateway_id: "stripe")
  end
  let(:existing_product_id) { 1 }

  let(:cart_response) do
    { "id" => "cart_1", "currency" => { "code" => "USD" }, "base_amount" => 5.0, "cart_amount" => 5.0,
      "line_items" => { "physical_items" => [
        { "id" => "item_1", "product_id" => 1, "name" => "Cold Brew", "quantity" => 1,
          "sale_price" => 5.0, "extended_sale_price" => 5.0, "extended_list_price" => 5.0 }
      ] } }
  end

  # #create_checkout creates a cart then fetches its matching checkout, and the
  # kit reaches nothing beyond that pair: the repeat call is served by
  # Support::Idempotency's in-process table, and the PAN example is rejected by
  # PaymentTokenGuard inside the Dispatcher before #complete_checkout (and so
  # before the orders/payments calls) runs.
  before do
    stub_request(:post, "https://api.bigcommerce.com/stores/abc123/v3/carts")
      .to_return(status: 200, body: { data: cart_response }.to_json)
    stub_request(:get, "https://api.bigcommerce.com/stores/abc123/v3/checkouts/cart_1")
      .to_return(status: 200, body: { data: { "cart" => cart_response, "subtotal" => 5.0, "tax_total" => 0.0,
                                              "grand_total" => 5.0 } }.to_json)
  end

  it_behaves_like "a portage adapter"
end
