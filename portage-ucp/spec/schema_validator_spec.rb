require "spec_helper"
require "portage/ucp/schema_validator"

RSpec.describe Portage::Ucp::SchemaValidator do
  let(:validator) { described_class.new }

  # Built from the real Portage::Ucp::Cart value object (not a hand-shaped double) —
  # proves Cart#to_wire_h, wrapped through WireEnvelope, actually conforms to
  # the vendored schema, with nested $refs (line_item.json -> item.json /
  # total.json) resolving fully offline.
  let(:valid_cart_payload) do
    item = Portage::Ucp::Item.new(id: "prod_1", title: "Cold Brew", price: 500)
    line_item = Portage::Ucp::LineItem.new(
      id: "li_1", item: item, quantity: 2,
      totals: [Portage::Ucp::Total.new(type: "subtotal", amount: 1000),
               Portage::Ucp::Total.new(type: "total", amount: 1000)]
    )
    cart = Portage::Ucp::Cart.new(
      id: "cart_1", line_items: [line_item], currency: "USD",
      totals: [Portage::Ucp::Total.new(type: "subtotal", amount: 1000),
               Portage::Ucp::Total.new(type: "total", amount: 1000)]
    )
    Portage::Ucp::WireEnvelope.wrap("dev.ucp.shopping.cart", cart.to_wire_h)
  end

  it "validates a spec-conformant Cart payload built from Portage::Ucp::Cart against the vendored schema" do
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

  # Built from the real Portage::Ucp::Order/OrderLineItem value objects — proves
  # the order_line_item quantity/status shape and the fulfillment/
  # checkout_id/permalink_url fields Order added this pass actually conform,
  # not just Cart/Checkout.
  let(:valid_order_payload) do
    item = Portage::Ucp::Item.new(id: "prod_1", title: "Cold Brew", price: 500)
    line_item = Portage::Ucp::OrderLineItem.new(
      id: "oli_1", item: item, quantity: { original: 2, total: 2, fulfilled: 2 },
      totals: [Portage::Ucp::Total.new(type: "subtotal", amount: 1000),
               Portage::Ucp::Total.new(type: "total", amount: 1000)],
      status: "fulfilled"
    )
    order = Portage::Ucp::Order.new(
      id: "order_1", checkout_id: "chk_1", permalink_url: "https://example.com/orders/1",
      line_items: [line_item], fulfillment: Portage::Ucp::Fulfillment.new, currency: "USD",
      totals: [Portage::Ucp::Total.new(type: "subtotal", amount: 1000),
               Portage::Ucp::Total.new(type: "total", amount: 1000)]
    )
    Portage::Ucp::WireEnvelope.wrap("dev.ucp.shopping.order", order.to_wire_h)
  end

  it "validates a spec-conformant Order payload built from Portage::Ucp::Order against the vendored schema" do
    expect(validator.errors_for("schemas/shopping/order.json", valid_order_payload)).to eq([])
  end

  # Proves the adjustments array cancel_order/request_return/refund_order
  # append (design-log §16) is itself schema-conformant, not just the base
  # Order shape.
  it "validates an Order payload carrying a refund Adjustment against the vendored schema" do
    refund = Portage::Ucp::Adjustment.new(
      id: "adj_1", type: "refund", occurred_at: "2026-08-20T00:00:00Z", status: "completed",
      line_items: [{ "id" => "oli_1", "quantity" => -1 }],
      totals: [Portage::Ucp::Total.new(type: "total", amount: -500)]
    )
    payload = Portage::Ucp::WireEnvelope.wrap("dev.ucp.shopping.order", valid_order_payload.merge(
                                                                          "adjustments" => [refund.to_wire_h]
                                                                        ))

    expect(validator.errors_for("schemas/shopping/order.json", payload)).to eq([])
  end

  describe "method_names" do
    it "lists the method names declared by the vendored UCP shopping MCP OpenRPC document" do
      names = validator.method_names("services/shopping/mcp.openrpc.json")

      expect(names).to include("create_checkout", "get_cart", "search_catalog", "get_order")
    end
  end

  describe "capability/spec conformance" do
    it "has all Catalog actions present in the real UCP method list" do
      real_methods = validator.method_names("services/shopping/mcp.openrpc.json")

      expect(Portage::Ucp::Capabilities::CATALOG.actions.keys - real_methods).to eq([])
    end

    # cancel_order/request_return/refund_order are a deliberate gem-side
    # extension of dev.ucp.shopping.order (design-log §16 "Order changes") —
    # the real UCP spec's order lifecycle is get-only. Naming them here keeps
    # these tests meaningful: any *other* drift from the real method list
    # still fails them, while these three stay an intentional, tracked
    # exception rather than a silent gap.
    let(:order_extension_actions) { %w[cancel_order request_return refund_order] }

    it "has all real (non-extension) Order actions present in the real UCP method list" do
      real_methods = validator.method_names("services/shopping/mcp.openrpc.json")
      spec_backed_actions = Portage::Ucp::Capabilities::ORDER.actions.keys - order_extension_actions

      expect(spec_backed_actions - real_methods).to eq([])
    end

    it "only ships the known, deliberate extension actions beyond the real UCP order method list" do
      real_methods = validator.method_names("services/shopping/mcp.openrpc.json")
      extension_actions = Portage::Ucp::Capabilities::ORDER.actions.keys - real_methods

      expect(extension_actions.sort).to eq(order_extension_actions.sort)
    end

    it "has all Checkout actions present in the real UCP method list" do
      real_methods = validator.method_names("services/shopping/mcp.openrpc.json")

      expect(Portage::Ucp::Capabilities::CHECKOUT.actions.keys - real_methods).to eq([])
    end

    it "has all Cart actions present in the real UCP method list (reconciled to full-replacement semantics)" do
      real_methods = validator.method_names("services/shopping/mcp.openrpc.json")

      expect(Portage::Ucp::Capabilities::CART.actions.keys - real_methods).to eq([])
    end
  end
end
