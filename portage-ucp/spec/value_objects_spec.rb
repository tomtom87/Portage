require "spec_helper"

RSpec.describe "Portage::Ucp value objects" do
  describe Portage::Ucp::Money do
    it "holds integer minor units and an ISO-4217 currency code" do
      money = Portage::Ucp::Money.new(amount_minor: 1_999, currency: "USD")
      expect(money.amount_minor).to eq(1_999)
      expect(money.currency).to eq("USD")
    end

    it "is immutable" do
      money = Portage::Ucp::Money.new(amount_minor: 100, currency: "USD")
      expect { money.instance_variable_set(:@amount_minor, 200) }.to raise_error(FrozenError)
    end
  end

  describe Portage::Ucp::Product do
    it "holds catalog fields" do
      product = Portage::Ucp::Product.new(
        id: "prod_1", title: "Coffee", description: "Cold brew",
        price: Portage::Ucp::Money.new(amount_minor: 500, currency: "USD"),
        available: true, variants: [], url: "https://example.com/prod_1"
      )
      expect(product.title).to eq("Coffee")
      expect(product.price.currency).to eq("USD")
    end
  end

  describe Portage::Ucp::Total do
    it "serializes type/amount, omitting display_text when absent" do
      total = Portage::Ucp::Total.new(type: "subtotal", amount: 1000)
      expect(total.to_wire_h).to eq({ "type" => "subtotal", "amount" => 1000 })
    end

    it "includes display_text when present" do
      total = Portage::Ucp::Total.new(type: "tax", amount: 50, display_text: "Sales Tax")
      expect(total.to_wire_h).to eq({ "type" => "tax", "amount" => 50, "display_text" => "Sales Tax" })
    end
  end

  describe Portage::Ucp::Item do
    it "holds product identity for a line item" do
      item = Portage::Ucp::Item.new(id: "prod_1", title: "Cold Brew", price: 500)
      expect(item.to_wire_h).to eq({ "id" => "prod_1", "title" => "Cold Brew", "price" => 500 })
    end
  end

  describe Portage::Ucp::LineItem do
    it "holds an item/quantity/totals triple, matching the real wire shape" do
      item = Portage::Ucp::Item.new(id: "prod_1", title: "Cold Brew", price: 500)
      totals = [Portage::Ucp::Total.new(type: "subtotal", amount: 1000),
                Portage::Ucp::Total.new(type: "total", amount: 1000)]
      line_item = Portage::Ucp::LineItem.new(id: "li_1", item: item, quantity: 2, totals: totals)

      expect(line_item.quantity).to eq(2)
      expect(line_item.to_wire_h).to eq(
        { "id" => "li_1", "item" => { "id" => "prod_1", "title" => "Cold Brew", "price" => 500 },
          "quantity" => 2,
          "totals" => [{ "type" => "subtotal", "amount" => 1000 }, { "type" => "total", "amount" => 1000 }] }
      )
    end
  end

  describe Portage::Ucp::Cart do
    it "holds line items and a totals array, with no ucp envelope of its own" do
      cart = Portage::Ucp::Cart.new(id: "cart_1", line_items: [], currency: "USD", totals: [])
      expect(cart.line_items).to eq([])
      expect(cart.to_wire_h).not_to have_key("ucp")
    end
  end

  describe Portage::Ucp::Checkout do
    it "holds checkout state with the real status enum and required links array" do
      checkout = Portage::Ucp::Checkout.new(id: "chk_1", status: "incomplete", line_items: [], currency: "USD",
                                            totals: [], links: [])
      expect(checkout.status).to eq("incomplete")
      expect(checkout.to_wire_h["links"]).to eq([])
    end

    it "omits order from the wire shape until a completion actually produces one" do
      checkout = Portage::Ucp::Checkout.new(id: "chk_1", status: "incomplete", line_items: [], currency: "USD",
                                            totals: [], links: [])
      expect(checkout.to_wire_h).not_to have_key("order")
    end

    it "includes the order confirmation once set" do
      order = Portage::Ucp::OrderConfirmation.new(id: "ord_1", permalink_url: "https://example.com/orders/1")
      checkout = Portage::Ucp::Checkout.new(id: "chk_1", status: "completed", line_items: [], currency: "USD",
                                            totals: [], links: [], order: order)
      expect(checkout.to_wire_h["order"]).to eq({ "id" => "ord_1", "permalink_url" => "https://example.com/orders/1" })
    end
  end

  describe Portage::Ucp::OrderConfirmation do
    it "serializes id/permalink_url, omitting label when absent" do
      confirmation = Portage::Ucp::OrderConfirmation.new(id: "ord_1", permalink_url: "https://example.com/orders/1")
      expect(confirmation.to_wire_h).to eq({ "id" => "ord_1", "permalink_url" => "https://example.com/orders/1" })
    end

    it "includes label when present" do
      confirmation = Portage::Ucp::OrderConfirmation.new(id: "ord_1", permalink_url: "https://example.com/orders/1",
                                                         label: "#1001")
      expect(confirmation.to_wire_h["label"]).to eq("#1001")
    end
  end

  describe Portage::Ucp::OrderLineItem do
    it "holds order-specific quantity tracking and a derived status" do
      item = Portage::Ucp::Item.new(id: "prod_1", title: "Cold Brew", price: 500)
      totals = [Portage::Ucp::Total.new(type: "subtotal", amount: 1000),
                Portage::Ucp::Total.new(type: "total", amount: 1000)]
      line_item = Portage::Ucp::OrderLineItem.new(
        id: "oli_1", item: item, quantity: { original: 2, total: 2, fulfilled: 1 },
        totals: totals, status: "partial"
      )

      expect(line_item.to_wire_h).to eq(
        { "id" => "oli_1", "item" => { "id" => "prod_1", "title" => "Cold Brew", "price" => 500 },
          "quantity" => { "total" => 2, "fulfilled" => 1, "original" => 2 },
          "totals" => [{ "type" => "subtotal", "amount" => 1000 }, { "type" => "total", "amount" => 1000 }],
          "status" => "partial" }
      )
    end
  end

  describe Portage::Ucp::Fulfillment do
    it "defaults to empty expectations/events" do
      expect(Portage::Ucp::Fulfillment.new.to_wire_h).to eq({ "expectations" => [], "events" => [] })
    end

    it "serializes expectations and events via their own to_wire_h" do
      expectation = Portage::Ucp::Expectation.new(
        id: "exp_1", line_items: [{ "id" => "oli_1", "quantity" => 1 }],
        method_type: "shipping", destination: { "postal_code" => "10001" }
      )
      event = Portage::Ucp::FulfillmentEvent.new(
        id: "evt_1", occurred_at: "2026-08-01T00:00:00Z", type: "shipped",
        line_items: [{ "id" => "oli_1", "quantity" => 1 }], tracking_number: "1Z999"
      )
      fulfillment = Portage::Ucp::Fulfillment.new(expectations: [expectation], events: [event])

      expect(fulfillment.to_wire_h).to eq(
        { "expectations" => [{ "id" => "exp_1", "line_items" => [{ "id" => "oli_1", "quantity" => 1 }],
                               "method_type" => "shipping", "destination" => { "postal_code" => "10001" } }],
          "events" => [{ "id" => "evt_1", "occurred_at" => "2026-08-01T00:00:00Z", "type" => "shipped",
                         "line_items" => [{ "id" => "oli_1", "quantity" => 1 }], "tracking_number" => "1Z999" }] }
      )
    end
  end

  describe Portage::Ucp::Adjustment do
    it "serializes required fields, omitting optional ones when absent" do
      adjustment = Portage::Ucp::Adjustment.new(id: "adj_1", type: "cancellation", occurred_at: "2026-08-01T00:00:00Z",
                                                status: "completed")
      expect(adjustment.to_wire_h).to eq(
        { "id" => "adj_1", "type" => "cancellation", "occurred_at" => "2026-08-01T00:00:00Z", "status" => "completed" }
      )
    end

    it "includes totals when present" do
      totals = [Portage::Ucp::Total.new(type: "total", amount: -500)]
      adjustment = Portage::Ucp::Adjustment.new(id: "adj_1", type: "refund", occurred_at: "2026-08-01T00:00:00Z",
                                                status: "completed", totals: totals)
      expect(adjustment.to_wire_h["totals"]).to eq([{ "type" => "total", "amount" => -500 }])
    end
  end

  describe Portage::Ucp::Order do
    it "holds order state with checkout_id/permalink_url/fulfillment and a totals array" do
      total = Portage::Ucp::Total.new(type: "total", amount: 500)
      order = Portage::Ucp::Order.new(id: "ord_1", checkout_id: "chk_1", permalink_url: "https://example.com/orders/1",
                                      line_items: [], fulfillment: Portage::Ucp::Fulfillment.new, currency: "USD",
                                      totals: [total])

      expect(order.checkout_id).to eq("chk_1")
      expect(order.to_wire_h["fulfillment"]).to eq({ "expectations" => [], "events" => [] })
      expect(order.to_wire_h["totals"]).to eq([{ "type" => "total", "amount" => 500 }])
      expect(order.to_wire_h).not_to have_key("adjustments")
    end

    it "includes adjustments when present" do
      total = Portage::Ucp::Total.new(type: "total", amount: 500)
      adjustment = Portage::Ucp::Adjustment.new(id: "adj_1", type: "cancellation", occurred_at: "2026-08-01T00:00:00Z",
                                                status: "completed")
      order = Portage::Ucp::Order.new(id: "ord_1", checkout_id: "chk_1", permalink_url: "https://example.com/orders/1",
                                      line_items: [], fulfillment: Portage::Ucp::Fulfillment.new, currency: "USD",
                                      totals: [total], adjustments: [adjustment])

      expect(order.to_wire_h["adjustments"]).to eq(
        [{ "id" => "adj_1", "type" => "cancellation", "occurred_at" => "2026-08-01T00:00:00Z",
           "status" => "completed" }]
      )
    end
  end

  describe Portage::Ucp::Identity do
    it "holds a linked identity" do
      identity = Portage::Ucp::Identity.new(subject: "sub_1", email: "a@example.com", linked_at: "2026-07-23T00:00:00Z")
      expect(identity.email).to eq("a@example.com")
    end
  end
end
