require "spec_helper"

RSpec.describe Portage::Ucp::Shopify::Adapter do
  let(:client) do
    Portage::Ucp::Shopify::Client.new(shop_domain: "test-shop.myshopify.com", admin_access_token: "admin-token",
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
                             "price" => { "amount" => "5.00", "currencyCode" => "USD" }, "availableForSale" => true } }
      ] }
    }
  end

  let(:empty_cart_response) { cart_response.merge("lines" => { "nodes" => [] }) }

  let(:cart_with_delivery_groups) do
    cart_response.merge("deliveryGroups" => { "nodes" => [
                          { "id" => "gid://shopify/CartDeliveryGroup/1",
                            "cartLines" => { "nodes" => [{ "id" => "gid://shopify/CartLine/1" }] },
                            "deliveryOptions" => [
                              { "handle" => "standard", "title" => "Standard", "description" => nil,
                                "deliveryMethodType" => "SHIPPING",
                                "estimatedCost" => { "amount" => "5.00", "currencyCode" => "USD" } }
                            ],
                            "selectedDeliveryOption" => nil,
                            "deliveryAddress" => { "address1" => "1 Main St", "address2" => nil, "city" => "Erie",
                                                   "provinceCode" => "PA", "zip" => "16501", "firstName" => "A",
                                                   "lastName" => "B", "phone" => nil, "countryCode" => "US" } }
                        ] })
  end

  let(:fulfillment_request) do
    Portage::Ucp::CheckoutFulfillment.new(
      shipping_methods: [
        Portage::Ucp::FulfillmentMethod.new(
          id: "fm_1", type: "shipping", line_item_ids: ["gid://shopify/CartLine/1"],
          destinations: [Portage::Ucp::ShippingDestination.new(
            id: "current", address: Portage::Ucp::PostalAddress.new(street_address: "1 Main St",
                                                                    address_locality: "Erie",
                                                                    address_region: "PA", postal_code: "16501",
                                                                    address_country: "US")
          )]
        )
      ]
    )
  end

  let(:out_of_stock_cart_response) do
    line = cart_response["lines"]["nodes"][0]
    unavailable = line["merchandise"].merge("availableForSale" => false)
    cart_response.merge("lines" => { "nodes" => [line.merge("merchandise" => unavailable)] })
  end

  # Accepts either one response body (a single stubbed response, repeated for
  # every call) or an array of bodies (sequential responses, one per call —
  # used to stub a SubmitThrottled poll followed by an eventual success).
  def stub_storefront(response_body_or_sequence)
    bodies = response_body_or_sequence.is_a?(Array) ? response_body_or_sequence : [response_body_or_sequence]
    stub_request(:post, "https://test-shop.myshopify.com/api/2026-04/graphql.json")
      .to_return(bodies.map { |body| { status: 200, body: body.to_json } })
  end

  def stub_admin(response_body)
    stub_request(:post, "https://test-shop.myshopify.com/admin/api/2026-04/graphql.json")
      .to_return(status: 200, body: response_body.to_json)
  end

  describe "capability advertisement (§2.1)" do
    it "only advertises capabilities backed by an overridden method — no Shopify identity linking" do
      registry = Portage::Ucp::CapabilityRegistry.default
      advertised_names = registry.advertised(adapter).map(&:name)

      expect(advertised_names).to include("dev.ucp.shopping.catalog", "dev.ucp.shopping.cart",
                                          "dev.ucp.shopping.checkout", "dev.ucp.shopping.order",
                                          "dev.ucp.shopping.fulfillment")
      expect(advertised_names).not_to include("dev.ucp.shopping.identity")
    end
  end

  describe "#search_catalog" do
    it "queries the Admin API and maps results to a Portage::Ucp::CatalogSearchResult" do
      stub_admin({ data: { products: { nodes: [
                   { id: "gid://shopify/Product/1", title: "Cold Brew", description: "desc", onlineStoreUrl: nil,
                     priceRange: { minVariantPrice: { amount: "5.00", currencyCode: "USD" },
                                   maxVariantPrice: { amount: "5.00", currencyCode: "USD" } },
                     variants: { nodes: [
                       { id: "gid://shopify/ProductVariant/1", title: "Default", availableForSale: true,
                         price: "5.00" }
                     ] } }
                 ] } } })

      result = adapter.search_catalog(query: "brew", limit: 10)

      expect(result).to be_a(Portage::Ucp::CatalogSearchResult)
      expect(result.products.first).to be_a(Portage::Ucp::Product)
      expect(result.products.first.title).to eq("Cold Brew")
    end

    it "sends a configured metadata_field's identifier even when configure ran after the gem was required" do
      Portage::Ucp::Shopify.configure { |c| c.metadata_field(:color_hex, metafield: "custom.color_code") }
      stub_admin({ data: { products: { nodes: [] } } })

      adapter.search_catalog(query: "brew", limit: 10)

      expect(a_request(:post, "https://test-shop.myshopify.com/admin/api/2026-04/graphql.json")
        .with(body: /metafields\(identifiers: \[\{namespace: \\"custom\\", key: \\"color_code\\"\}\]\)/))
        .to have_been_made
    ensure
      Portage::Ucp::Shopify.instance_variable_set(:@configuration, nil)
    end
  end

  describe "#get_cart" do
    it "queries the Storefront API and maps the result to a Portage::Ucp::Cart" do
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

      expect(cart).to be_a(Portage::Ucp::Cart)
      expect(stub).to have_been_requested
    end

    it "raises UserError when cartCreate returns userErrors" do
      stub_storefront({ data: { cartCreate: { cart: nil, userErrors: [{ field: "lines",
                                                                        message: "variant not found" }] } } })

      expect do
        adapter.create_cart(line_items: [{ product_id: "bad", quantity: 1 }], idempotency_key: "k1")
      end.to raise_error(Portage::Ucp::Shopify::UserError, /variant not found/)
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

    it "passes discount_codes through to cartCreate's input when given" do
      stub = stub_storefront({ data: { cartCreate: { cart: cart_response, userErrors: [] } } })
             .with(body: hash_including("variables" => hash_including(
               "input" => hash_including("discountCodes" => ["SAVE10"])
             )))

      adapter.create_cart(line_items: [{ product_id: "gid://shopify/ProductVariant/1", quantity: 1 }],
                          idempotency_key: "k2", discount_codes: ["SAVE10"])

      expect(stub).to have_been_requested
    end

    it "omits discountCodes from cartCreate's input when not given" do
      stub = stub_storefront({ data: { cartCreate: { cart: cart_response, userErrors: [] } } })
             .with(body: hash_including("variables" => hash_including(
               "input" => { "lines" => [{ "merchandiseId" => "gid://shopify/ProductVariant/1", "quantity" => 1 }] }
             )))

      adapter.create_cart(line_items: [{ product_id: "gid://shopify/ProductVariant/1", quantity: 1 }],
                          idempotency_key: "k3")

      expect(stub).to have_been_requested
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

      expect(cart).to be_a(Portage::Ucp::Cart)
      expect(remove_stub).to have_been_requested
      expect(add_stub).to have_been_requested
    end

    it "does not touch discounts when discount_codes is omitted (nil means untouched, not clear)" do
      stub_storefront({ data: { cart: cart_response } })
        .with(body: hash_including("query" => a_string_matching(/query GetCart/)))
      stub_storefront({ data: { cartLinesRemove: { cart: empty_cart_response, userErrors: [] } } })
        .with(body: hash_including("query" => a_string_matching(/mutation CartLinesRemove/)))
      stub_storefront({ data: { cartLinesAdd: { cart: cart_response, userErrors: [] } } })
        .with(body: hash_including("query" => a_string_matching(/mutation CartLinesAdd/)))
      discount_stub = stub_storefront({ data: { cartDiscountCodesUpdate: { cart: cart_response, userErrors: [] } } })
                      .with(body: hash_including("query" => a_string_matching(/mutation CartDiscountCodesUpdate/)))

      adapter.update_cart(cart_id: "gid://shopify/Cart/1",
                          line_items: [{ product_id: "gid://shopify/ProductVariant/1", quantity: 1 }],
                          idempotency_key: "k4")

      expect(discount_stub).not_to have_been_requested
    end

    it "replaces discount codes, sending an empty array to clear them" do
      stub_storefront({ data: { cart: cart_response } })
        .with(body: hash_including("query" => a_string_matching(/query GetCart/)))
      stub_storefront({ data: { cartLinesRemove: { cart: empty_cart_response, userErrors: [] } } })
        .with(body: hash_including("query" => a_string_matching(/mutation CartLinesRemove/)))
      stub_storefront({ data: { cartLinesAdd: { cart: cart_response, userErrors: [] } } })
        .with(body: hash_including("query" => a_string_matching(/mutation CartLinesAdd/)))
      discount_stub = stub_storefront({ data: { cartDiscountCodesUpdate: { cart: cart_response, userErrors: [] } } })
                      .with(body: hash_including("variables" => hash_including("discountCodes" => [])))

      adapter.update_cart(cart_id: "gid://shopify/Cart/1",
                          line_items: [{ product_id: "gid://shopify/ProductVariant/1", quantity: 1 }],
                          idempotency_key: "k5", discount_codes: [])

      expect(discount_stub).to have_been_requested
    end
  end

  describe "#discount_codes_supported?" do
    it "advertises dev.ucp.shopping.discount" do
      registry = Portage::Ucp::CapabilityRegistry.default
      expect(registry.advertised(adapter).map(&:name)).to include("dev.ucp.shopping.discount")
    end
  end

  describe "#cancel_cart" do
    it "returns the cart unchanged (Shopify has no cart-cancellation mutation)" do
      stub_storefront({ data: { cart: cart_response } })

      cart = adapter.cancel_cart(cart_id: "gid://shopify/Cart/1", idempotency_key: "k1")

      expect(cart).to be_a(Portage::Ucp::Cart)
    end
  end

  describe "#create_checkout" do
    it "builds cart lines from requested line items and returns status incomplete" do
      stub_storefront({ data: { cartCreate: { cart: cart_response, userErrors: [] } } })

      checkout = adapter.create_checkout(line_items: [{ product_id: "gid://shopify/ProductVariant/1", quantity: 1 }],
                                         idempotency_key: "chk1")

      expect(checkout).to be_a(Portage::Ucp::Checkout)
      expect(checkout.status).to eq("incomplete")
      expect(checkout.id).to eq("gid://shopify/Cart/1")
    end

    it "submits the agent's shipping destination via cartDeliveryAddressesAdd when fulfillment is requested" do
      stub_storefront({ data: { cartCreate: { cart: cart_response, userErrors: [] } } })
        .with(body: hash_including("query" => a_string_matching(/mutation CartCreate/)))
      stub_storefront({ data: { cart: cart_response } })
        .with(body: hash_including("query" => a_string_matching(/query GetCart/)))
      address_stub = stub_storefront(
        { data: { cartDeliveryAddressesAdd: { cart: cart_with_delivery_groups, userErrors: [] } } }
      ).with(body: hash_including(
        "query" => a_string_matching(/mutation CartDeliveryAddressesAdd/),
        "variables" => hash_including(
          "addresses" => [{ "address" => { "deliveryAddress" => { "address1" => "1 Main St", "city" => "Erie",
                                                                  "provinceCode" => "PA", "zip" => "16501",
                                                                  "countryCode" => "US" } },
                            "selected" => true }]
        )
      ))

      checkout = adapter.create_checkout(line_items: [{ product_id: "gid://shopify/ProductVariant/1", quantity: 1 }],
                                         idempotency_key: "chk2", fulfillment: fulfillment_request)

      expect(address_stub).to have_been_requested
      expect(checkout.to_wire_h.dig("fulfillment", "methods", 0, "type")).to eq("shipping")
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

  describe "#update_checkout" do
    it "submits the agent's selected_option_id via cartSelectedDeliveryOptionsUpdate" do
      stub_storefront({ data: { cart: cart_with_delivery_groups } })
        .with(body: hash_including("query" => a_string_matching(/query GetCart/)))
      stub_storefront({ data: { cartLinesRemove: { cart: empty_cart_response, userErrors: [] } } })
        .with(body: hash_including("query" => a_string_matching(/mutation CartLinesRemove/)))
      stub_storefront({ data: { cartLinesAdd: { cart: cart_with_delivery_groups, userErrors: [] } } })
        .with(body: hash_including("query" => a_string_matching(/mutation CartLinesAdd/)))
      cart_with_selection = cart_with_delivery_groups.tap do |c|
        c["deliveryGroups"]["nodes"][0]["selectedDeliveryOption"] = { "handle" => "standard" }
      end
      selection_stub = stub_storefront(
        { data: { cartSelectedDeliveryOptionsUpdate: { cart: cart_with_selection, userErrors: [] } } }
      ).with(body: hash_including(
        "query" => a_string_matching(/mutation CartSelectedDeliveryOptionsUpdate/),
        "variables" => hash_including(
          "selectedDeliveryOptions" => [{ "deliveryGroupId" => "gid://shopify/CartDeliveryGroup/1",
                                          "deliveryOptionHandle" => "standard" }]
        )
      ))

      fulfillment = Portage::Ucp::CheckoutFulfillment.new(
        shipping_methods: [
          Portage::Ucp::FulfillmentMethod.new(
            id: "fm_1", type: "shipping", line_item_ids: ["gid://shopify/CartLine/1"],
            groups: [Portage::Ucp::FulfillmentGroup.new(id: "gid://shopify/CartDeliveryGroup/1",
                                                        line_item_ids: ["gid://shopify/CartLine/1"],
                                                        selected_option_id: "standard")]
          )
        ]
      )

      checkout = adapter.update_checkout(checkout_id: "gid://shopify/Cart/1",
                                         line_items: [{ product_id: "gid://shopify/ProductVariant/1", quantity: 1 }],
                                         idempotency_key: "chk3", fulfillment: fulfillment)

      expect(selection_stub).to have_been_requested
      expect(checkout.to_wire_h.dig("fulfillment", "methods", 0, "groups", 0, "selected_option_id"))
        .to eq("standard")
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
      stub_admin({ data: { orders: { nodes: [{ id: "gid://shopify/Order/1",
                                               statusPageUrl: "https://ucp-test.myshopify.com/orders/abc123" }] } } })

      checkout = adapter.complete_checkout(checkout_id: "gid://shopify/Cart/1", payment_token: "tok_abc123",
                                           idempotency_key: "chk1-complete")

      expect(checkout.status).to eq("completed")
      expect(checkout.order).to eq(
        Portage::Ucp::OrderConfirmation.new(id: "gid://shopify/Order/1",
                                            permalink_url: "https://ucp-test.myshopify.com/orders/abc123")
      )
    end

    it "links the cart to the resulting order via a cart_token order search, for #get_order's checkout_id" do
      stub_storefront({ data: { cart: cart_response } })
        .with(body: hash_including("query" => a_string_matching(/query GetCart/)))
      stub_storefront({ data: { cartPaymentUpdate: { cart: cart_response, userErrors: [] } } })
        .with(body: hash_including("query" => a_string_matching(/mutation CartPaymentUpdate/)))
      stub_storefront({ data: { cartSubmitForCompletion: { result: { attemptId: "a1" }, userErrors: [] } } })
        .with(body: hash_including("query" => a_string_matching(/mutation CartSubmitForCompletion/)))
      order_stub = stub_admin({ data: { orders: { nodes: [{ id: "gid://shopify/Order/1" }] } } })
                   .with(body: hash_including("variables" => { "query" => "cart_token:1" }))

      adapter.complete_checkout(checkout_id: "gid://shopify/Cart/1", payment_token: "tok_abc123",
                                idempotency_key: "chk1-link")
      stub_admin({ data: { order: { id: "gid://shopify/Order/1", statusPageUrl: nil,
                                    currentTotalPriceSet: { shopMoney: { amount: "5.00", currencyCode: "USD" } },
                                    currentSubtotalPriceSet: { shopMoney: { amount: "5.00", currencyCode: "USD" } },
                                    lineItems: { nodes: [] } } } })
      order = adapter.get_order(order_id: "gid://shopify/Order/1")

      expect(order_stub).to have_been_requested
      expect(order.checkout_id).to eq("gid://shopify/Cart/1")
    end

    it "polls through a SubmitThrottled response and returns completed once Shopify finishes" do
      stub_storefront({ data: { cart: cart_response } })
        .with(body: hash_including("query" => a_string_matching(/query GetCart/)))
      stub_storefront({ data: { cartPaymentUpdate: { cart: cart_response, userErrors: [] } } })
        .with(body: hash_including("query" => a_string_matching(/mutation CartPaymentUpdate/)))
      stub_storefront([
                        { data: { cartSubmitForCompletion: { result: { pollAfter: "2026-07-24T00:00:05Z" },
                                                             userErrors: [] } } },
                        { data: { cartSubmitForCompletion: { result: { attemptId: "a1" }, userErrors: [] } } }
                      ]).with(body: hash_including("query" => a_string_matching(/mutation CartSubmitForCompletion/)))
      stub_admin({ data: { orders: { nodes: [] } } })

      checkout = adapter.complete_checkout(checkout_id: "gid://shopify/Cart/1", payment_token: "tok_abc123",
                                           idempotency_key: "chk1-poll")

      expect(checkout.status).to eq("completed")
    end

    it "raises Portage::Ucp::UpstreamThrottledError once SubmitThrottled retries are exhausted" do
      stub_storefront({ data: { cart: cart_response } })
        .with(body: hash_including("query" => a_string_matching(/query GetCart/)))
      stub_storefront({ data: { cartPaymentUpdate: { cart: cart_response, userErrors: [] } } })
        .with(body: hash_including("query" => a_string_matching(/mutation CartPaymentUpdate/)))
      stub_storefront({ data: { cartSubmitForCompletion: { result: { pollAfter: "2026-07-24T00:00:05Z" },
                                                           userErrors: [] } } })
        .with(body: hash_including("query" => a_string_matching(/mutation CartSubmitForCompletion/)))

      expect do
        adapter.complete_checkout(checkout_id: "gid://shopify/Cart/1", payment_token: "tok_abc123",
                                  idempotency_key: "chk1-poll-exhausted")
      end.to raise_error(Portage::Ucp::UpstreamThrottledError)
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
      end.to raise_error(Portage::Ucp::Shopify::Error, /card declined/)
    end

    it "raises Portage::Ucp::OutOfStockError when a cart line is no longer available for sale, " \
       "before attempting payment" do
      stub_storefront({ data: { cart: out_of_stock_cart_response } })
        .with(body: hash_including("query" => a_string_matching(/query GetCart/)))
      payment_stub =
        stub_storefront({ data: { cartPaymentUpdate: { cart: cart_response, userErrors: [] } } })
        .with(body: hash_including("query" => a_string_matching(/mutation CartPaymentUpdate/)))

      expect do
        adapter.complete_checkout(checkout_id: "gid://shopify/Cart/1", payment_token: "tok_abc123",
                                  idempotency_key: "chk1-oos")
      end.to raise_error(Portage::Ucp::OutOfStockError, /Cold Brew/)
      expect(payment_stub).not_to have_been_requested
    end
  end

  describe "#get_order" do
    it "queries the Admin API and maps the result to a Portage::Ucp::Order" do
      stub_admin({ data: { order: {
                   id: "gid://shopify/Order/1", statusPageUrl: "https://ucp-test.myshopify.com/orders/abc123",
                   currentTotalPriceSet: { shopMoney: { amount: "5.00", currencyCode: "USD" } },
                   currentSubtotalPriceSet: { shopMoney: { amount: "5.00", currencyCode: "USD" } },
                   lineItems: { nodes: [] }
                 } } })

      order = adapter.get_order(order_id: "gid://shopify/Order/1")

      expect(order).to be_a(Portage::Ucp::Order)
      expect(order.permalink_url).to eq("https://ucp-test.myshopify.com/orders/abc123")
    end

    it "returns nil for an order the API doesn't find" do
      stub_admin({ data: { order: nil } })

      expect(adapter.get_order(order_id: "gid://shopify/Order/nonexistent")).to be_nil
    end
  end

  let(:order_node) do
    { id: "gid://shopify/Order/1", statusPageUrl: "https://ucp-test.myshopify.com/orders/abc123",
      currentTotalPriceSet: { shopMoney: { amount: "5.00", currencyCode: "USD" } },
      currentSubtotalPriceSet: { shopMoney: { amount: "5.00", currencyCode: "USD" } },
      lineItems: { nodes: [] } }
  end

  describe "#cancel_order" do
    it "cancels via orderCancel, then re-fetches the order for current state (§16)" do
      cancel_stub = stub_admin({ data: { orderCancel: { job: { id: "gid://shopify/Job/1", done: false },
                                                        orderCancelUserErrors: [] } } })
                    .with(body: hash_including("query" => a_string_matching(/mutation OrderCancel/)))
      stub_admin({ data: { order: order_node.merge(cancelledAt: "2026-08-20T00:00:00Z", cancelReason: "CUSTOMER") } })
        .with(body: hash_including("query" => a_string_matching(/query GetOrder/)))

      order = adapter.cancel_order(order_id: "gid://shopify/Order/1", idempotency_key: "can1", reason: "changed mind")

      expect(cancel_stub).to have_been_requested
      expect(order.adjustments.map(&:type)).to eq(["cancellation"])
    end

    it "raises on an orderCancelUserErrors response" do
      stub_admin({ data: { orderCancel: { job: nil,
                                          orderCancelUserErrors: [{ field: ["orderId"], message: "not found" }] } } })

      expect { adapter.cancel_order(order_id: "gid://shopify/Order/x", idempotency_key: "can2") }
        .to raise_error(Portage::Ucp::Shopify::UserError, /not found/)
    end

    it "dedups a repeated idempotency_key without re-calling orderCancel" do
      cancel_stub = stub_admin({ data: { orderCancel: { job: { id: "j1", done: false }, orderCancelUserErrors: [] } } })
                    .with(body: hash_including("query" => a_string_matching(/mutation OrderCancel/)))
      stub_admin({ data: { order: order_node } })
        .with(body: hash_including("query" => a_string_matching(/query GetOrder/)))

      2.times { adapter.cancel_order(order_id: "gid://shopify/Order/1", idempotency_key: "can-dedup") }

      expect(cancel_stub).to have_been_requested.times(1)
    end
  end

  describe "#refund_order" do
    it "quotes a suggestedRefund, feeds its transactions into refundCreate, then re-fetches the order" do
      stub_admin({ data: { order: { suggestedRefund: { transactions: [
                   { orderId: "gid://shopify/Order/1", gateway: "bogus", kind: "REFUND",
                     amountSet: { shopMoney: { amount: "5.00", currencyCode: "USD" } },
                     parentTransaction: { id: "gid://shopify/OrderTransaction/1" } }
                 ] } } } })
        .with(body: hash_including("query" => a_string_matching(/query SuggestedRefund/)))
      refund_stub = stub_admin(
        { data: { refundCreate: { refund: { id: "gid://shopify/Refund/1" }, userErrors: [] } } }
      ).with(body: hash_including("query" => a_string_matching(/mutation RefundCreate/)))
      stub_admin({ data: { order: order_node.merge(
        refunds: [{ id: "gid://shopify/Refund/1", createdAt: "2026-08-20T00:00:00Z", note: "damaged",
                    totalRefundedSet: { shopMoney: { amount: "5.00", currencyCode: "USD" } },
                    refundLineItems: { nodes: [{ quantity: 1, lineItem: { id: "gid://shopify/LineItem/1" } }] } }]
      ) } }).with(body: hash_including("query" => a_string_matching(/query GetOrder/)))

      order = adapter.refund_order(order_id: "gid://shopify/Order/1",
                                   line_items: [{ id: "gid://shopify/LineItem/1", quantity: 1 }],
                                   idempotency_key: "ref1", reason: "damaged")

      expect(refund_stub).to have_been_requested
      expect(order.adjustments.map(&:type)).to eq(["refund"])
    end

    it "raises on a refundCreate userErrors response" do
      stub_admin({ data: { order: { suggestedRefund: { transactions: [] } } } })
        .with(body: hash_including("query" => a_string_matching(/query SuggestedRefund/)))
      stub_admin({ data: { refundCreate: { refund: nil,
                                           userErrors: [{ field: ["quantity"], message: "too high" }] } } })
        .with(body: hash_including("query" => a_string_matching(/mutation RefundCreate/)))

      expect do
        adapter.refund_order(order_id: "gid://shopify/Order/1",
                             line_items: [{ id: "gid://shopify/LineItem/1", quantity: 99 }],
                             idempotency_key: "ref2")
      end.to raise_error(Portage::Ucp::Shopify::UserError, /too high/)
    end
  end

  describe "#request_return" do
    it "requests a return via returnCreate, then re-fetches the order" do
      return_stub = stub_admin(
        { data: { returnCreate: { return: { id: "gid://shopify/Return/1", status: "OPEN" }, userErrors: [] } } }
      ).with(body: hash_including("query" => a_string_matching(/mutation ReturnCreate/)))
      stub_admin({ data: { order: order_node.merge(
        returns: { nodes: [{ id: "gid://shopify/Return/1", status: "OPEN", requestedAt: "2026-08-20T00:00:00Z",
                             returnLineItems: { nodes: [
                               { quantity: 1, returnReasonNote: "wrong size",
                                 fulfillmentLineItem: { lineItem: { id: "gid://shopify/LineItem/1" } } }
                             ] } }] }
      ) } }).with(body: hash_including("query" => a_string_matching(/query GetOrder/)))

      order = adapter.request_return(order_id: "gid://shopify/Order/1",
                                     line_items: [{ id: "gid://shopify/FulfillmentLineItem/1", quantity: 1 }],
                                     idempotency_key: "ret1", reason: "wrong size")

      expect(return_stub).to have_been_requested
      expect(order.adjustments.map(&:type)).to eq(["return"])
      expect(order.adjustments.first.status).to eq("pending")
    end

    it "raises on a returnCreate userErrors response" do
      stub_admin({ data: { returnCreate: { return: nil,
                                           userErrors: [{ field: ["quantity"], message: "unfulfilled" }] } } })

      expect do
        adapter.request_return(order_id: "gid://shopify/Order/1",
                               line_items: [{ id: "gid://shopify/FulfillmentLineItem/1", quantity: 1 }],
                               idempotency_key: "ret2")
      end.to raise_error(Portage::Ucp::Shopify::UserError, /unfulfilled/)
    end
  end
end
