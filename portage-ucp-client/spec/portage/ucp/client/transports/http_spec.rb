require "spec_helper"

RSpec.describe Portage::Ucp::Client::Transports::Http do
  let(:mcp_transport) { instance_double(MCP::Client::HTTP) }
  let(:mcp_client) { instance_double(MCP::Client) }
  let(:agent_meta) { { agent_profile: "https://agent.example/profile" } }
  let(:wire_meta) { { "ucp-agent" => { "profile" => "https://agent.example/profile" } } }

  before do
    allow(MCP::Client::HTTP).to receive(:new).with(url: "https://shop.example/mcp", headers: {})
                                             .and_return(mcp_transport)
    allow(MCP::Client).to receive(:new).with(transport: mcp_transport).and_return(mcp_client)
    allow(mcp_client).to receive(:connect)
    allow(mcp_client).to receive(:call_tool)
      .and_return({ "result" => { "isError" => false, "content" => [], "structuredContent" => [] } })
  end

  subject(:transport) { described_class.new(url: "https://shop.example/mcp") }

  it "connects the underlying MCP::Client eagerly" do
    expect(mcp_client).to receive(:connect)

    described_class.new(url: "https://shop.example/mcp")
  end

  it "raises MissingAgentProfileError when meta has no agent_profile" do
    expect { transport.call_tool(name: "search_catalog", arguments: { query: "x", limit: 1 }) }
      .to raise_error(Portage::Ucp::Client::MissingAgentProfileError)
  end

  # Shopify's own tool schemas list "meta" as a property of the tool's
  # `arguments` object, not the MCP protocol's `_meta` envelope field —
  # confirmed live, so every assertion below checks `arguments["meta"]`
  # rather than a `meta:` kwarg passed to the underlying MCP::Client.
  it "nests search_catalog's query/limit under catalog and folds meta into arguments" do
    transport.call_tool(name: "search_catalog", arguments: { query: "x", limit: 1 }, meta: agent_meta)

    expect(mcp_client).to have_received(:call_tool).with(
      name: "search_catalog",
      arguments: { "catalog" => { "query" => "x", "pagination" => { "limit" => 1 } }, "meta" => wire_meta }
    )
  end

  it "nests get_product under catalog with id" do
    transport.call_tool(name: "get_product", arguments: { product_id: "p1" }, meta: agent_meta)

    expect(mcp_client).to have_received(:call_tool)
      .with(name: "get_product", arguments: { "catalog" => { "id" => "p1" }, "meta" => wire_meta })
  end

  it "nests lookup_catalog under catalog with ids" do
    transport.call_tool(name: "lookup_catalog", arguments: { product_ids: %w[p1 p2] }, meta: agent_meta)

    expect(mcp_client).to have_received(:call_tool)
      .with(name: "lookup_catalog", arguments: { "catalog" => { "ids" => %w[p1 p2] }, "meta" => wire_meta })
  end

  it "flattens a plain id-only action to a top-level id" do
    transport.call_tool(name: "get_cart", arguments: { cart_id: "c1" }, meta: agent_meta)

    expect(mcp_client).to have_received(:call_tool)
      .with(name: "get_cart", arguments: { "id" => "c1", "meta" => wire_meta })
  end

  it "flattens a mutating id-only action's id and moves idempotency_key into meta" do
    transport.call_tool(name: "cancel_checkout", arguments: { checkout_id: "co1", idempotency_key: "k" },
                        meta: agent_meta)

    expect(mcp_client).to have_received(:call_tool).with(
      name: "cancel_checkout",
      arguments: { "id" => "co1", "meta" => wire_meta.merge("idempotency-key" => "k") }
    )
  end

  it "wraps create_cart's line_items as {item: {id:}, quantity:} and moves idempotency_key into meta" do
    transport.call_tool(name: "create_cart",
                        arguments: { line_items: [{ product_id: "v1", quantity: 2 }], idempotency_key: "k1" },
                        meta: agent_meta)

    expect(mcp_client).to have_received(:call_tool).with(
      name: "create_cart",
      arguments: { "cart" => { "line_items" => [{ "item" => { "id" => "v1" }, "quantity" => 2 }] },
                   "meta" => wire_meta.merge("idempotency-key" => "k1") }
    )
  end

  it "includes an id for update_cart/update_checkout, wrapped under cart/checkout" do
    transport.call_tool(name: "update_checkout",
                        arguments: { checkout_id: "co1", line_items: [{ product_id: "v1", quantity: 1 }] },
                        meta: agent_meta)

    expect(mcp_client).to have_received(:call_tool).with(
      name: "update_checkout",
      arguments: { "checkout" => { "line_items" => [{ "item" => { "id" => "v1" }, "quantity" => 1 }] },
                   "id" => "co1", "meta" => wire_meta }
    )
  end

  # Not cosmetic: a real store resolves which market (and so which inventory)
  # a call is scoped to from `context`, and a cart built without one comes
  # back empty with a `merchandise_out_of_stock` warning for a product the
  # same store's search just reported as available. See #with_context.
  it "passes a buyer context through under the capability key on a catalog call" do
    transport.call_tool(name: "search_catalog",
                        arguments: { query: "x", limit: 1, context: { address_country: "US", currency: "USD" } },
                        meta: agent_meta)

    expect(mcp_client).to have_received(:call_tool).with(
      name: "search_catalog",
      arguments: { "catalog" => { "query" => "x", "pagination" => { "limit" => 1 },
                                  "context" => { "address_country" => "US", "currency" => "USD" } },
                   "meta" => wire_meta }
    )
  end

  it "passes a buyer context through on a cart call" do
    transport.call_tool(name: "create_cart",
                        arguments: { line_items: [{ product_id: "v1", quantity: 1 }],
                                     context: { address_country: "US" } },
                        meta: agent_meta)

    expect(mcp_client).to have_received(:call_tool).with(
      name: "create_cart",
      arguments: { "cart" => { "line_items" => [{ "item" => { "id" => "v1" }, "quantity" => 1 }],
                               "context" => { "address_country" => "US" } },
                   "meta" => wire_meta }
    )
  end

  it "omits an empty or absent context rather than sending a bare key" do
    transport.call_tool(name: "get_product", arguments: { product_id: "p1", context: {} }, meta: agent_meta)

    expect(mcp_client).to have_received(:call_tool)
      .with(name: "get_product", arguments: { "catalog" => { "id" => "p1" }, "meta" => wire_meta })
  end

  # `checkout.cart_id`'s own schema says it's sufficient on its own; the live
  # server rejects a cart_id-only body for missing line_items, so both go out.
  it "sends cart_id alongside line_items on create_checkout" do
    transport.call_tool(name: "create_checkout",
                        arguments: { cart_id: "gid://shopify/Cart/c1?key=k",
                                     line_items: [{ product_id: "v1", quantity: 1 }] },
                        meta: agent_meta)

    expect(mcp_client).to have_received(:call_tool).with(
      name: "create_checkout",
      arguments: { "checkout" => { "line_items" => [{ "item" => { "id" => "v1" }, "quantity" => 1 }],
                                   "cart_id" => "gid://shopify/Cart/c1?key=k" },
                   "meta" => wire_meta }
    )
  end

  describe "complete_checkout" do
    it "builds checkout.payment.instruments[] for the card handler, with idempotency-key in meta" do
      transport.call_tool(name: "complete_checkout",
                          arguments: { checkout_id: "co1", payment_token: "tok", idempotency_key: "k1" },
                          meta: agent_meta)

      expect(mcp_client).to have_received(:call_tool).with(
        name: "complete_checkout",
        arguments: {
          "id" => "co1",
          "checkout" => { "payment" => { "instruments" => [
            { "id" => "instrument-k1", "handler_id" => "dev.shopify.card", "type" => "card",
              "credential" => { "token" => "tok", "type" => "dev.shopify.card_token" } }
          ] } },
          "meta" => wire_meta.merge("idempotency-key" => "k1")
        }
      )
    end

    it "lets the caller override handler_id/credential_type for the card handler" do
      transport.call_tool(
        name: "complete_checkout",
        arguments: { checkout_id: "co1", payment_token: "tok", idempotency_key: "k1",
                     handler_id: "dev.shopify.card", credential_type: "custom_type" },
        meta: agent_meta
      )

      expect(mcp_client).to have_received(:call_tool) do |name:, arguments:|
        expect(name).to eq("complete_checkout")
        instrument = arguments.dig("checkout", "payment", "instruments", 0)
        expect(instrument["credential"]).to eq("token" => "tok", "type" => "custom_type")
      end
    end

    it "raises UnsupportedWireShapeError naming an unsupported handler, without calling the server" do
      expect(mcp_client).not_to receive(:call_tool)

      expect do
        transport.call_tool(name: "complete_checkout",
                            arguments: { checkout_id: "co1", payment_token: "tok", idempotency_key: "k1",
                                         handler_id: "apple-pay" },
                            meta: agent_meta)
      end.to raise_error(Portage::Ucp::Client::UnsupportedWireShapeError, /apple-pay/)
    end

    it "wraps a permission-shaped ServerError as PaymentPermissionError" do
      allow(mcp_client).to receive(:call_tool).and_return(
        { "result" => { "isError" => true,
                        "content" => [{ "type" => "text", "text" => "checkout-completion not granted" }] } }
      )

      expect do
        transport.call_tool(name: "complete_checkout",
                            arguments: { checkout_id: "co1", payment_token: "tok", idempotency_key: "k1" },
                            meta: agent_meta)
      end.to raise_error(Portage::Ucp::Client::PaymentPermissionError, /checkout-completion not granted/)
    end

    it "leaves an unrelated ServerError (e.g. a malformed request) unwrapped" do
      allow(mcp_client).to receive(:call_tool).and_return(
        { "result" => { "isError" => true, "content" => [{ "type" => "text", "text" => "Invalid arguments" }] } }
      )

      expect do
        transport.call_tool(name: "complete_checkout",
                            arguments: { checkout_id: "co1", payment_token: "tok", idempotency_key: "k1" },
                            meta: agent_meta)
      end.to raise_error(Portage::Ucp::Client::ServerError, "Invalid arguments")
    end
  end

  it "raises ServerError when the response reports isError" do
    allow(mcp_client).to receive(:call_tool).and_return(
      { "result" => { "isError" => true, "content" => [{ "type" => "text", "text" => "boom" }] } }
    )

    expect { transport.call_tool(name: "get_order", arguments: { order_id: "o1" }, meta: agent_meta) }
      .to raise_error(Portage::Ucp::Client::ServerError, "boom")
  end
end
