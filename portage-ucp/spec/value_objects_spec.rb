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

    it "omits discounts from the wire shape when nothing was ever submitted or applied" do
      cart = Portage::Ucp::Cart.new(id: "cart_1", line_items: [], currency: "USD", totals: [])
      expect(cart.to_wire_h).not_to have_key("discounts")
    end

    it "includes discounts once codes or applied discounts exist" do
      discounts = Portage::Ucp::Discounts.new(codes: ["SAVE10"])
      cart = Portage::Ucp::Cart.new(id: "cart_1", line_items: [], currency: "USD", totals: [], discounts: discounts)
      expect(cart.to_wire_h["discounts"]).to eq({ "codes" => ["SAVE10"] })
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

    it "omits fulfillment from the wire shape when no methods were ever offered" do
      checkout = Portage::Ucp::Checkout.new(id: "chk_1", status: "incomplete", line_items: [], currency: "USD",
                                            totals: [], links: [])
      expect(checkout.to_wire_h).not_to have_key("fulfillment")
    end

    it "includes fulfillment once a method exists" do
      method = Portage::Ucp::FulfillmentMethod.new(id: "fm_1", type: "shipping", line_item_ids: ["li_1"])
      fulfillment = Portage::Ucp::CheckoutFulfillment.new(shipping_methods: [method])
      checkout = Portage::Ucp::Checkout.new(id: "chk_1", status: "incomplete", line_items: [], currency: "USD",
                                            totals: [], links: [], fulfillment: fulfillment)
      expect(checkout.to_wire_h["fulfillment"]).to eq(
        "methods" => [{ "id" => "fm_1", "type" => "shipping", "line_item_ids" => ["li_1"] }]
      )
    end

    it "includes discounts once codes or applied discounts exist" do
      discounts = Portage::Ucp::Discounts.new(codes: [], applied: [
                                                Portage::Ucp::AppliedDiscount.new(title: "10% Off", amount: 100)
                                              ])
      checkout = Portage::Ucp::Checkout.new(id: "chk_1", status: "incomplete", line_items: [], currency: "USD",
                                            totals: [], links: [], discounts: discounts)
      expect(checkout.to_wire_h["discounts"]).to eq("applied" => [{ "title" => "10% Off", "amount" => 100 }])
    end
  end

  describe Portage::Ucp::Discounts do
    it "is empty with no codes and no applied discounts" do
      expect(Portage::Ucp::Discounts.new).to be_empty
    end

    it "serializes codes and applied discounts, omitting whichever side is empty" do
      applied = Portage::Ucp::AppliedDiscount.new(title: "Summer Sale 20% Off", amount: 500, code: "SUMMER20")
      discounts = Portage::Ucp::Discounts.new(codes: ["summer20"], applied: [applied])
      expect(discounts.to_wire_h).to eq(
        "codes" => ["summer20"],
        "applied" => [{ "title" => "Summer Sale 20% Off", "amount" => 500, "code" => "SUMMER20" }]
      )
    end
  end

  describe Portage::Ucp::AppliedDiscount do
    it "requires only title/amount, omitting optional fields when unset" do
      discount = Portage::Ucp::AppliedDiscount.new(title: "Free Shipping", amount: 0)
      expect(discount.to_wire_h).to eq("title" => "Free Shipping", "amount" => 0)
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

  describe Portage::Ucp::PostalAddress do
    it "serializes only the fields present" do
      address = Portage::Ucp::PostalAddress.new(street_address: "1 Main St", address_locality: "Mountain View",
                                                address_region: "CA", address_country: "US", postal_code: "94043")
      expect(address.to_wire_h).to eq(
        "street_address" => "1 Main St", "address_locality" => "Mountain View", "address_region" => "CA",
        "address_country" => "US", "postal_code" => "94043"
      )
    end
  end

  describe Portage::Ucp::ShippingDestination do
    it "merges the postal address with its own id" do
      address = Portage::Ucp::PostalAddress.new(postal_code: "94043")
      destination = Portage::Ucp::ShippingDestination.new(id: "dest_1", address: address)
      expect(destination.to_wire_h).to eq("postal_code" => "94043", "id" => "dest_1")
    end
  end

  describe Portage::Ucp::RetailLocation do
    it "requires id/name, omitting address when absent" do
      location = Portage::Ucp::RetailLocation.new(id: "loc_1", name: "Downtown Store")
      expect(location.to_wire_h).to eq("id" => "loc_1", "name" => "Downtown Store")
    end
  end

  describe Portage::Ucp::FulfillmentOption do
    it "serializes id/title/totals, omitting optional fields when absent" do
      totals = [Portage::Ucp::Total.new(type: "total", amount: 500)]
      option = Portage::Ucp::FulfillmentOption.new(id: "opt_1", title: "Standard Shipping", totals: totals)
      expect(option.to_wire_h).to eq(
        "id" => "opt_1", "title" => "Standard Shipping", "totals" => [{ "type" => "total", "amount" => 500 }]
      )
    end
  end

  describe Portage::Ucp::FulfillmentGroup do
    it "defaults to no options and no selection" do
      group = Portage::Ucp::FulfillmentGroup.new(id: "grp_1", line_item_ids: ["li_1"])
      expect(group.to_wire_h).to eq(
        "id" => "grp_1", "line_item_ids" => ["li_1"], "options" => [], "selected_option_id" => nil
      )
    end

    it "carries the agent's selected option id" do
      option = Portage::Ucp::FulfillmentOption.new(id: "opt_1", title: "Express",
                                                   totals: [Portage::Ucp::Total.new(type: "total", amount: 1500)])
      group = Portage::Ucp::FulfillmentGroup.new(id: "grp_1", line_item_ids: ["li_1"], options: [option],
                                                 selected_option_id: "opt_1")
      expect(group.to_wire_h["selected_option_id"]).to eq("opt_1")
    end
  end

  describe Portage::Ucp::FulfillmentMethod do
    it "requires id/type/line_item_ids, omitting destinations/groups when absent" do
      method = Portage::Ucp::FulfillmentMethod.new(id: "fm_1", type: "pickup", line_item_ids: ["li_1"])
      expect(method.to_wire_h).to eq("id" => "fm_1", "type" => "pickup", "line_item_ids" => ["li_1"])
    end

    it "includes destinations/selected_destination_id/groups once present" do
      destination = Portage::Ucp::ShippingDestination.new(id: "dest_1",
                                                          address: Portage::Ucp::PostalAddress.new(postal_code: "1"))
      group = Portage::Ucp::FulfillmentGroup.new(id: "grp_1", line_item_ids: ["li_1"])
      method = Portage::Ucp::FulfillmentMethod.new(id: "fm_1", type: "shipping", line_item_ids: ["li_1"],
                                                   destinations: [destination], selected_destination_id: "dest_1",
                                                   groups: [group])
      wire = method.to_wire_h
      expect(wire["destinations"]).to eq([{ "postal_code" => "1", "id" => "dest_1" }])
      expect(wire["selected_destination_id"]).to eq("dest_1")
      expect(wire["groups"]).to eq([{ "id" => "grp_1", "line_item_ids" => ["li_1"], "options" => [],
                                      "selected_option_id" => nil }])
    end
  end

  describe Portage::Ucp::CheckoutFulfillment do
    it "is empty with no methods and no available_methods" do
      expect(Portage::Ucp::CheckoutFulfillment.new).to be_empty
    end

    it "serializes methods and available_methods, omitting whichever side is empty" do
      method = Portage::Ucp::FulfillmentMethod.new(id: "fm_1", type: "shipping", line_item_ids: ["li_1"])
      fulfillment = Portage::Ucp::CheckoutFulfillment.new(shipping_methods: [method])
      expect(fulfillment.to_wire_h).to eq(
        "methods" => [{ "id" => "fm_1", "type" => "shipping", "line_item_ids" => ["li_1"] }]
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
