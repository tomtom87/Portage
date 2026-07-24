require "spec_helper"
require "ucp_mcp/schema_validator"

RSpec.describe UcpMcp::SchemaValidator do
  let(:validator) { described_class.new }

  # A hand-built payload shaped per UCP's actual wire schema (cart.json ->
  # line_item.json -> item.json / total.json), not UcpMcp::Cart's Ruby shape
  # — see the mismatch noted below. Proves the vendored $refs resolve fully
  # offline, several levels deep, with no network access.
  let(:valid_cart) do
    {
      "ucp" => { "version" => "2026-04-08" },
      "id" => "cart_1",
      "currency" => "USD",
      "line_items" => [
        { "id" => "li_1", "quantity" => 2,
          "item" => { "id" => "prod_1", "title" => "Cold Brew", "price" => 500 },
          "totals" => [{ "type" => "subtotal", "amount" => 1000 }, { "type" => "total", "amount" => 1000 }] }
      ],
      "totals" => [
        { "type" => "subtotal", "amount" => 1000 },
        { "type" => "total", "amount" => 1000 }
      ]
    }
  end

  it "validates a spec-conformant Cart payload against the vendored schema, resolving nested $refs offline" do
    expect(validator.errors_for("schemas/shopping/cart.json", valid_cart)).to eq([])
  end

  it "reports errors for a payload missing a required field" do
    invalid_cart = valid_cart.except("line_items")

    expect(validator.errors_for("schemas/shopping/cart.json", invalid_cart)).not_to be_empty
  end

  it "reports errors when totals is missing the required subtotal/total entries" do
    invalid_cart = valid_cart.merge("totals" => [{ "type" => "tax", "amount" => 50 }])

    expect(validator.errors_for("schemas/shopping/cart.json", invalid_cart)).not_to be_empty
  end

  describe "method_names" do
    it "lists the method names declared by the vendored UCP shopping MCP OpenRPC document" do
      names = validator.method_names("services/shopping/mcp.openrpc.json")

      expect(names).to include("create_checkout", "get_cart", "search_catalog", "get_order")
    end
  end

  describe "capability/spec conformance" do
    # This is today's real, verified overlap between ucp_mcp's own
    # Capability action names and UCP's actual MCP method names — not an
    # aspiration. Catalog and Order line up exactly; Checkout's three verbs
    # are a subset of the real spec's five (get_checkout/cancel_checkout
    # aren't modeled yet); Cart is the one capability that's diverged
    # further — UCP's real cart methods are full-replacement
    # (create_cart/update_cart/cancel_cart), not ucp_mcp's item-level
    # add_line_item/remove_line_item. Reconciling Cart's method shape is
    # real follow-up work, tracked separately — this spec exists so that
    # gap stays visible instead of silently assumed away.
    it "has all Catalog and Order actions present in the real UCP method list" do
      real_methods = validator.method_names("services/shopping/mcp.openrpc.json")

      catalog_and_order_actions = (UcpMcp::Capabilities::CATALOG.actions.keys + UcpMcp::Capabilities::ORDER.actions.keys)

      expect(catalog_and_order_actions - real_methods).to eq([])
    end

    it "has all Checkout actions present in the real UCP method list (a strict subset of it)" do
      real_methods = validator.method_names("services/shopping/mcp.openrpc.json")

      expect(UcpMcp::Capabilities::CHECKOUT.actions.keys - real_methods).to eq([])
    end

    it "documents that Cart's action names do not match the real UCP method list yet" do
      real_methods = validator.method_names("services/shopping/mcp.openrpc.json")

      expect(UcpMcp::Capabilities::CART.actions.keys - real_methods).to eq(%w[add_line_item remove_line_item])
    end
  end
end
