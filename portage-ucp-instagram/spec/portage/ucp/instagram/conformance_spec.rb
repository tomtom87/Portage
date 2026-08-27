require "spec_helper"
require "portage/ucp/rspec"

# Design-log §17: runs the shipped conformance kit against the real Instagram
# Adapter through a real Dispatcher. Same shape as Etsy's — catalog/checkout/
# order advertised, no cart, checkout is a redirect link rather than a
# completable transaction (§16), and the kit's checkout examples still run.
RSpec.describe Portage::Ucp::Instagram::Adapter do
  let(:client) { Portage::Ucp::Instagram::Client.new(access_token: "acc-tok") }
  let(:adapter) { described_class.new(client: client, catalog_id: "catalog_1") }
  let(:existing_product_id) { "1" }

  # The product fetch is the only network call the kit reaches: the repeat call
  # is served by Support::Idempotency's in-process table, and the PAN example
  # is rejected by PaymentTokenGuard inside the Dispatcher — so Instagram's
  # #complete_checkout NotImplementedError is never what makes it pass.
  before do
    stub_request(:get, "https://graph.facebook.com/v21.0/1?fields=id,name,price,url")
      .to_return(status: 200,
                 body: { "id" => "1", "name" => "Handmade Mug", "description" => "desc", "price" => "25.00 USD",
                         "availability" => "in stock",
                         "url" => "https://merchant.example.com/products/mug" }.to_json)
  end

  it_behaves_like "a portage adapter"
end
