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
          "merchandise" => { "id" => "gid://shopify/ProductVariant/1",
                             "price" => { "amount" => "5.00", "currencyCode" => "USD" } } }
      ] }
    }
  end

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
      expect(cart.subtotal).to eq(UcpMcp::Money.new(amount_minor: 500, currency: "USD"))
    end
  end

  describe "#add_line_item" do
    it "sends the product_id as the cart line's merchandiseId" do
      stub = stub_storefront({ data: { cartLinesAdd: { cart: cart_response, userErrors: [] } } })
             .with(body: hash_including("variables" => hash_including(
               "cartId" => "gid://shopify/Cart/1",
               "lines" => [{ "merchandiseId" => "gid://shopify/ProductVariant/1", "quantity" => 1 }]
             )))

      cart = adapter.add_line_item(cart_id: "gid://shopify/Cart/1", product_id: "gid://shopify/ProductVariant/1",
                                   quantity: 1, idempotency_key: "k1")

      expect(cart).to be_a(UcpMcp::Cart)
      expect(stub).to have_been_requested
    end

    it "raises UserError when cartLinesAdd returns userErrors" do
      stub_storefront({ data: { cartLinesAdd: { cart: nil, userErrors: [{ field: "lines",
                                                                          message: "variant not found" }] } } })

      expect do
        adapter.add_line_item(cart_id: "gid://shopify/Cart/1", product_id: "bad", quantity: 1,
                              idempotency_key: "k1")
      end.to raise_error(UcpMcp::Shopify::UserError, /variant not found/)
    end

    it "dedups by idempotency_key instead of re-issuing the mutation (§9a)" do
      stub = stub_storefront({ data: { cartLinesAdd: { cart: cart_response, userErrors: [] } } })

      first = adapter.add_line_item(cart_id: "gid://shopify/Cart/1", product_id: "gid://shopify/ProductVariant/1",
                                    quantity: 1, idempotency_key: "dupe")
      second = adapter.add_line_item(cart_id: "gid://shopify/Cart/1", product_id: "gid://shopify/ProductVariant/1",
                                     quantity: 1, idempotency_key: "dupe")

      expect(second).to equal(first)
      expect(stub).to have_been_requested.once
    end
  end

  describe "#create_checkout" do
    it "builds cart lines from already-priced UcpMcp::LineItem input and returns status pending" do
      line_item = UcpMcp::LineItem.new(id: "li_1", product_id: "gid://shopify/ProductVariant/1", quantity: 1,
                                       unit_price: UcpMcp::Money.new(amount_minor: 500, currency: "USD"),
                                       total: UcpMcp::Money.new(amount_minor: 500, currency: "USD"))
      stub_storefront({ data: { cartCreate: { cart: cart_response, userErrors: [] } } })

      checkout = adapter.create_checkout(line_items: [line_item], idempotency_key: "chk1")

      expect(checkout).to be_a(UcpMcp::Checkout)
      expect(checkout.status).to eq("pending")
      expect(checkout.id).to eq("gid://shopify/Cart/1")
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
