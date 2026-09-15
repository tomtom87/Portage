require "spec_helper"
require "portage/ucp/rspec"

# Design-log §17: runs the shipped conformance kit against the real Wix
# Adapter through a real Dispatcher. Discount/fulfillment/identity examples
# self-skip — Wix advertises catalog/cart/checkout/order only.
RSpec.describe Portage::Ucp::Wix::Adapter do
  let(:client) { Portage::Ucp::Wix::Client.new(access_token: "site-token") }
  let(:adapter) { described_class.new(client: client) }
  let(:existing_product_id) { "var_1" }

  let(:checkout_response) do
    {
      "id" => "checkout_1", "currency" => "USD",
      "priceSummary" => { "subtotal" => { "amount" => "5.00" }, "total" => { "amount" => "5.00" } },
      "lineItems" => [
        { "id" => "line_1", "quantity" => 1, "price" => { "amount" => "5.00" },
          "catalogReference" => { "catalogItemId" => "var_1" }, "productName" => { "original" => "Cold Brew" } }
      ]
    }
  end

  # Same product node shape as mapper_spec.rb's ".product" examples, keyed
  # under existing_product_id so both #search_catalog and #get_product map
  # to a schema-conformant Portage::Ucp::Product.
  let(:product_node) do
    {
      "id" => "var_1", "name" => "Cold Brew", "description" => "desc",
      "priceData" => { "price" => 5.0, "currency" => "USD" },
      "stock" => { "inStock" => true },
      "productPageUrl" => { "base" => "https://site.wixsite.com/store", "path" => "/product-page/cold-brew" },
      "variants" => [
        { "id" => "var_1", "choices" => { "Size" => "Large" }, "stock" => { "inStock" => true },
          "variant" => { "priceData" => { "price" => 5.0 } } }
      ]
    }
  end

  # `POST /ecom/v1/checkouts`, and the catalog reads the kit's schema
  # examples make directly (search_catalog/get_product): the repeat-call
  # example is served by Support::Idempotency's in-process table, and the
  # PAN example is rejected by PaymentTokenGuard inside the Dispatcher
  # before #complete_checkout (and so before Wix's create-order) runs.
  before do
    stub_request(:post, "https://www.wixapis.com/ecom/v1/checkouts")
      .to_return(status: 200, body: { checkout: checkout_response }.to_json)
    stub_request(:post, "https://www.wixapis.com/stores/v1/products/query")
      .to_return(status: 200, body: { products: [product_node] }.to_json)
    stub_request(:get, "https://www.wixapis.com/stores/v1/products/var_1")
      .to_return(status: 200, body: { product: product_node }.to_json)
  end

  it_behaves_like "a portage adapter"
end
