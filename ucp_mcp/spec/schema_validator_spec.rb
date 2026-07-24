require "spec_helper"
require "ucp_mcp/schema_validator"

RSpec.describe UcpMcp::SchemaValidator do
  let(:validator) { described_class.new }

  # Built from the real UcpMcp::Cart value object (not a hand-shaped double) —
  # proves Cart#to_wire_h, wrapped through WireEnvelope, actually conforms to
  # the vendored schema, with nested $refs (line_item.json -> item.json /
  # total.json) resolving fully offline.
  let(:valid_cart_payload) do
    item = UcpMcp::Item.new(id: "prod_1", title: "Cold Brew", price: 500)
    line_item = UcpMcp::LineItem.new(
      id: "li_1", item: item, quantity: 2,
      totals: [UcpMcp::Total.new(type: "subtotal", amount: 1000), UcpMcp::Total.new(type: "total", amount: 1000)]
    )
    cart = UcpMcp::Cart.new(
      id: "cart_1", line_items: [line_item], currency: "USD",
      totals: [UcpMcp::Total.new(type: "subtotal", amount: 1000), UcpMcp::Total.new(type: "total", amount: 1000)]
    )
    UcpMcp::WireEnvelope.wrap("dev.ucp.shopping.cart", cart.to_wire_h)
  end

  it "validates a spec-conformant Cart payload built from UcpMcp::Cart against the vendored schema" do
    expect(validator.errors_for("schemas/shopping/cart.json", valid_cart_payload)).to eq([])
  end

  it "reports errors for a payload missing a required field" do
    invalid_cart = valid_cart_payload.except("line_items")

    expect(validator.errors_for("schemas/shopping/cart.json", invalid_cart)).not_to be_empty
  end

  it "reports errors when totals is missing the required subtotal/total entries" do
    invalid_cart = valid_cart_payload.merge("totals" => [{ "type" => "tax", "amount" => 50 }])

    expect(validator.errors_for("schemas/shopping/cart.json", invalid_cart)).not_to be_empty
  end

  describe "method_names" do
    it "lists the method names declared by the vendored UCP shopping MCP OpenRPC document" do
      names = validator.method_names("services/shopping/mcp.openrpc.json")

      expect(names).to include("create_checkout", "get_cart", "search_catalog", "get_order")
    end
  end

  describe "capability/spec conformance" do
    it "has all Catalog and Order actions present in the real UCP method list" do
      real_methods = validator.method_names("services/shopping/mcp.openrpc.json")

      catalog_and_order_actions = (UcpMcp::Capabilities::CATALOG.actions.keys + UcpMcp::Capabilities::ORDER.actions.keys)

      expect(catalog_and_order_actions - real_methods).to eq([])
    end

    it "has all Checkout actions present in the real UCP method list" do
      real_methods = validator.method_names("services/shopping/mcp.openrpc.json")

      expect(UcpMcp::Capabilities::CHECKOUT.actions.keys - real_methods).to eq([])
    end

    it "has all Cart actions present in the real UCP method list (reconciled to full-replacement semantics)" do
      real_methods = validator.method_names("services/shopping/mcp.openrpc.json")

      expect(UcpMcp::Capabilities::CART.actions.keys - real_methods).to eq([])
    end
  end
end
