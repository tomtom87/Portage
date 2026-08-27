require "spec_helper"
require "portage/ucp/rspec"

# Design-log §17: runs the shipped conformance kit against the real Shopify
# Adapter, not a test double — the kit routes every call through a real
# Dispatcher, so this is the same path an MCP client takes.
#
# The Storefront fixture is deliberately inline rather than shared with
# adapter_spec.rb: this file is the thing a third-party adapter author copies
# as a starting point, so it has to read standalone, and the kit needs exactly
# one response shape (see below) where adapter_spec.rb needs a dozen.
RSpec.describe Portage::Ucp::Shopify::Adapter do
  let(:client) do
    Portage::Ucp::Shopify::Client.new(shop_domain: "test-shop.myshopify.com", admin_access_token: "admin-token",
                                      storefront_access_token: "storefront-token")
  end
  let(:adapter) { described_class.new(client: client) }
  let(:existing_product_id) { "gid://shopify/ProductVariant/1" }

  let(:cart_response) do
    {
      "id" => "gid://shopify/Cart/1",
      "checkoutUrl" => "https://test-shop.myshopify.com/cart/c/1",
      "cost" => { "subtotalAmount" => { "amount" => "5.00", "currencyCode" => "USD" },
                  "totalTaxAmount" => { "amount" => "0.00", "currencyCode" => "USD" },
                  "totalAmount" => { "amount" => "5.00", "currencyCode" => "USD" } },
      "lines" => { "nodes" => [
        { "id" => "gid://shopify/CartLine/1", "quantity" => 1,
          "cost" => { "totalAmount" => { "amount" => "5.00", "currencyCode" => "USD" } },
          "merchandise" => { "id" => "gid://shopify/ProductVariant/1", "product" => { "title" => "Cold Brew" },
                             "price" => { "amount" => "5.00", "currencyCode" => "USD" }, "availableForSale" => true } }
      ] }
    }
  end

  # One fixed response per URL is enough here, and that's worth spelling out
  # because the §17 handoff note assumed otherwise: the kit fires `cartCreate`
  # and nothing else against the network. Its repeat-call example is answered
  # from `Support::Idempotency`'s in-process dedup table (no second HTTP call),
  # and its PAN example is rejected by `PaymentTokenGuard` inside the
  # Dispatcher before `complete_checkout` — hence before `cartPaymentUpdate` /
  # `cartSubmitForCompletion` — ever runs. If a future kit example completes a
  # checkout for real, this stub has to start matching on the request body.
  before do
    stub_request(:post, "https://test-shop.myshopify.com/api/2026-04/graphql.json")
      .to_return(status: 200, body: { "data" => { "cartCreate" => { "cart" => cart_response,
                                                                    "userErrors" => [] } } }.to_json)
  end

  it_behaves_like "a portage adapter"
end
