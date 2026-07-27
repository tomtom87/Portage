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

  describe Portage::Ucp::Order do
    it "holds order state with checkout_id/permalink_url/fulfillment and a totals array" do
      total = Portage::Ucp::Total.new(type: "total", amount: 500)
      order = Portage::Ucp::Order.new(id: "ord_1", checkout_id: "chk_1", permalink_url: "https://example.com/orders/1",
                                      line_items: [], fulfillment: {}, currency: "USD", totals: [total])

      expect(order.checkout_id).to eq("chk_1")
      expect(order.to_wire_h["fulfillment"]).to eq({})
      expect(order.to_wire_h["totals"]).to eq([{ "type" => "total", "amount" => 500 }])
    end
  end

  describe Portage::Ucp::Identity do
    it "holds a linked identity" do
      identity = Portage::Ucp::Identity.new(subject: "sub_1", email: "a@example.com", linked_at: "2026-07-23T00:00:00Z")
      expect(identity.email).to eq("a@example.com")
    end
  end
end
