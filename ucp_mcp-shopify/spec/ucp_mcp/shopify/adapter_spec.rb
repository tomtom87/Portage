require "spec_helper"

RSpec.describe UcpMcp::Shopify::Adapter do
  let(:client) do
    UcpMcp::Shopify::Client.new(shop_domain: "test-shop.myshopify.com", admin_access_token: "admin-token",
                                storefront_access_token: "storefront-token")
  end
  let(:adapter) { described_class.new(client: client) }

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
                             "price" => { "amount" => "5.00", "currencyCode" => "USD" } } }
      ] }
    }
  end

  let(:empty_cart_response) { cart_response.merge("lines" => { "nodes" => [] }) }

  def stub_storefront(response_body)
    stub_request(:post, "https://test-shop.myshopify.com/api/2026-04/graphql.json")
      .to_return(status: 200, body: response_body.to_json)
  end

  def stub_admin(response_body)
    stub_request(:post, "https://test-shop.myshopify.com/admin/api/2026-04/graphql.json")
      .to_return(status: 200, body: response_body.to_json)
  end

  describe "capability advertisement (§2.1)" do
    it "only advertises capabilities backed by an overridden method — no Shopify identity linking" do
      registry = UcpMcp::CapabilityRegistry.default
      advertised_names = registry.advertised(adapter).map(&:name)

      expect(advertised_names).to include("dev.ucp.shopping.catalog", "dev.ucp.shopping.cart",
                                          "dev.ucp.shopping.checkout", "dev.ucp.shopping.order")
      expect(advertised_names).not_to include("dev.ucp.shopping.identity")
    end
  end

  describe "#search_catalog" do
    it "queries the Admin API and maps results to UcpMcp::Product" do
      stub_admin({ data: { products: { nodes: [
                   { id: "gid://shopify/Product/1", title: "Cold Brew", description: "desc", onlineStoreUrl: nil,
                     availableForSale: true,
                     priceRange: { minVariantPrice: { amount: "5.00", currencyCode: "USD" } },
                     variants: { nodes: [] } }
                 ] } } })

      products = adapter.search_catalog(query: "brew", limit: 10)

      expect(products.first).to be_a(UcpMcp::Product)
      expect(products.first.title).to eq("Cold Brew")
    end
  end

  describe "#get_cart" do
    it "queries the Storefront API and maps the result to a UcpMcp::Cart" do
      stub_storefront({ data: { cart: cart_response } })

      cart = adapter.get_cart(cart_id: "gid://shopify/Cart/1")

      expect(cart.line_items.size).to eq(1)
      expect(cart.totals.find { |t| t.type == "total" }.amount).to eq(500)
    end
  end

  describe "#create_cart" do
    it "sends the product_id as the cart line's merchandiseId" do
      stub = stub_storefront({ data: { cartCreate: { cart: cart_response, userErrors: [] } } })
             .with(body: hash_including("variables" => hash_including(
               "input" => { "lines" => [{ "merchandiseId" => "gid://shopify/ProductVariant/1", "quantity" => 1 }] }
             )))

      cart = adapter.create_cart(line_items: [{ product_id: "gid://shopify/ProductVariant/1", quantity: 1 }],
                                 idempotency_key: "k1")

      expect(cart).to be_a(UcpMcp::Cart)
      expect(stub).to have_been_requested
    end

    it "raises UserError when cartCreate returns userErrors" do
      stub_storefront({ data: { cartCreate: { cart: nil, userErrors: [{ field: "lines",
                                                                        message: "variant not found" }] } } })

      expect do
        adapter.create_cart(line_items: [{ product_id: "bad", quantity: 1 }], idempotency_key: "k1")
      end.to raise_error(UcpMcp::Shopify::UserError, /variant not found/)
    end

    it "dedups by idempotency_key instead of re-issuing the mutation (§9a)" do
      stub = stub_storefront({ data: { cartCreate: { cart: cart_response, userErrors: [] } } })

      first = adapter.create_cart(line_items: [{ product_id: "gid://shopify/ProductVariant/1", quantity: 1 }],
                                  idempotency_key: "dupe")
      second = adapter.create_cart(line_items: [{ product_id: "gid://shopify/ProductVariant/1", quantity: 1 }],
                                   idempotency_key: "dupe")

      expect(second).to equal(first)
      expect(stub).to have_been_requested.once
    end
  end

  describe "#update_cart" do
    it "replaces all lines by removing the current ones then adding the desired ones" do
      stub_storefront({ data: { cart: cart_response } })
        .with(body: hash_including("query" => a_string_matching(/query GetCart/)))
      remove_stub = stub_storefront({ data: { cartLinesRemove: { cart: empty_cart_response, userErrors: [] } } })
                    .with(body: hash_including("query" => a_string_matching(/mutation CartLinesRemove/)))
      add_stub = stub_storefront({ data: { cartLinesAdd: { cart: cart_response, userErrors: [] } } })
                 .with(body: hash_including("query" => a_string_matching(/mutation CartLinesAdd/)))

      cart = adapter.update_cart(cart_id: "gid://shopify/Cart/1",
                                 line_items: [{ product_id: "gid://shopify/ProductVariant/1", quantity: 1 }],
                                 idempotency_key: "k1")

      expect(cart).to be_a(UcpMcp::Cart)
      expect(remove_stub).to have_been_requested
      expect(add_stub).to have_been_requested
    end
  end

  describe "#cancel_cart" do
    it "returns the cart unchanged (Shopify has no cart-cancellation mutation)" do
      stub_storefront({ data: { cart: cart_response } })

      cart = adapter.cancel_cart(cart_id: "gid://shopify/Cart/1", idempotency_key: "k1")

      expect(cart).to be_a(UcpMcp::Cart)
    end
  end

  describe "#create_checkout" do
    it "builds cart lines from requested line items and returns status incomplete" do
      stub_storefront({ data: { cartCreate: { cart: cart_response, userErrors: [] } } })

      checkout = adapter.create_checkout(line_items: [{ product_id: "gid://shopify/ProductVariant/1", quantity: 1 }],
                                         idempotency_key: "chk1")

      expect(checkout).to be_a(UcpMcp::Checkout)
      expect(checkout.status).to eq("incomplete")
      expect(checkout.id).to eq("gid://shopify/Cart/1")
    end
  end

  describe "#get_checkout" do
    it "maps the underlying cart to a Checkout with the last-tracked status" do
      stub_storefront({ data: { cartCreate: { cart: cart_response, userErrors: [] } } })
      adapter.create_checkout(line_items: [{ product_id: "gid://shopify/ProductVariant/1", quantity: 1 }],
                              idempotency_key: "chk1")
      stub_storefront({ data: { cart: cart_response } })

      checkout = adapter.get_checkout(checkout_id: "gid://shopify/Cart/1")

      expect(checkout.status).to eq("incomplete")
    end
  end

  describe "#cancel_checkout" do
    it "marks the tracked status canceled" do
      stub_storefront({ data: { cart: cart_response } })

      checkout = adapter.cancel_checkout(checkout_id: "gid://shopify/Cart/1", idempotency_key: "k1")

      expect(checkout.status).to eq("canceled")
    end
  end

  describe "#complete_checkout" do
    it "submits payment then submits for completion, returning status completed on success" do
      stub_storefront({ data: { cart: cart_response } })
        .with(body: hash_including("query" => a_string_matching(/query GetCart/)))
      stub_storefront({ data: { cartPaymentUpdate: { cart: cart_response, userErrors: [] } } })
        .with(body: hash_including("query" => a_string_matching(/mutation CartPaymentUpdate/)))
      stub_storefront({ data: { cartSubmitForCompletion: { result: { attemptId: "a1" }, userErrors: [] } } })
        .with(body: hash_including("query" => a_string_matching(/mutation CartSubmitForCompletion/)))

      checkout = adapter.complete_checkout(checkout_id: "gid://shopify/Cart/1", payment_token: "tok_abc123",
                                           idempotency_key: "chk1-complete")

      expect(checkout.status).to eq("completed")
    end

    it "maps a poll-required submission to complete_in_progress" do
      stub_storefront({ data: { cart: cart_response } })
        .with(body: hash_including("query" => a_string_matching(/query GetCart/)))
      stub_storefront({ data: { cartPaymentUpdate: { cart: cart_response, userErrors: [] } } })
        .with(body: hash_including("query" => a_string_matching(/mutation CartPaymentUpdate/)))
      stub_storefront({ data: { cartSubmitForCompletion: { result: { pollAfter: "2026-07-24T00:00:05Z" },
                                                           userErrors: [] } } })
        .with(body: hash_including("query" => a_string_matching(/mutation CartSubmitForCompletion/)))

      checkout = adapter.complete_checkout(checkout_id: "gid://shopify/Cart/1", payment_token: "tok_abc123",
                                           idempotency_key: "chk1-poll")

      expect(checkout.status).to eq("complete_in_progress")
    end

    it "raises when cartSubmitForCompletion reports a SubmitFailed result" do
      stub_storefront({ data: { cart: cart_response } })
        .with(body: hash_including("query" => a_string_matching(/query GetCart/)))
      stub_storefront({ data: { cartPaymentUpdate: { cart: cart_response, userErrors: [] } } })
        .with(body: hash_including("query" => a_string_matching(/mutation CartPaymentUpdate/)))
      stub_storefront(
        { data: { cartSubmitForCompletion: { result: { errors: [{ message: "card declined" }] },
                                             userErrors: [] } } }
      ).with(body: hash_including("query" => a_string_matching(/mutation CartSubmitForCompletion/)))

      expect do
        adapter.complete_checkout(checkout_id: "gid://shopify/Cart/1", payment_token: "tok_abc123",
                                  idempotency_key: "chk1-complete")
      end.to raise_error(UcpMcp::Shopify::Error, /card declined/)
    end
  end

  describe "#get_order" do
    it "queries the Admin API and maps the result to a UcpMcp::Order" do
      stub_admin({ data: { order: {
                   id: "gid://shopify/Order/1", displayFulfillmentStatus: "UNFULFILLED",
                   currentTotalPriceSet: { shopMoney: { amount: "5.00", currencyCode: "USD" } },
                   createdAt: "2026-07-24T00:00:00Z", lineItems: { nodes: [] }
                 } } })

      order = adapter.get_order(order_id: "gid://shopify/Order/1")

      expect(order).to be_a(UcpMcp::Order)
      expect(order.status).to eq("UNFULFILLED")
    end

    it "returns nil for an order the API doesn't find" do
      stub_admin({ data: { order: nil } })

      expect(adapter.get_order(order_id: "gid://shopify/Order/nonexistent")).to be_nil
    end
  end
end
