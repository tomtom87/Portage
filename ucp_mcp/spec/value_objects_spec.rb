require "spec_helper"

RSpec.describe "UcpMcp value objects" do
  describe UcpMcp::Money do
    it "holds integer minor units and an ISO-4217 currency code" do
      money = UcpMcp::Money.new(amount_minor: 1_999, currency: "USD")
      expect(money.amount_minor).to eq(1_999)
      expect(money.currency).to eq("USD")
    end

    it "is immutable" do
      money = UcpMcp::Money.new(amount_minor: 100, currency: "USD")
      expect { money.instance_variable_set(:@amount_minor, 200) }.to raise_error(FrozenError)
    end
  end

  describe UcpMcp::Product do
    it "holds catalog fields" do
      product = UcpMcp::Product.new(
        id: "prod_1", title: "Coffee", description: "Cold brew",
        price: UcpMcp::Money.new(amount_minor: 500, currency: "USD"),
        available: true, variants: [], url: "https://example.com/prod_1"
      )
      expect(product.title).to eq("Coffee")
      expect(product.price.currency).to eq("USD")
    end
  end

  describe UcpMcp::Total do
    it "serializes type/amount, omitting display_text when absent" do
      total = UcpMcp::Total.new(type: "subtotal", amount: 1000)
      expect(total.to_wire_h).to eq({ "type" => "subtotal", "amount" => 1000 })
    end

    it "includes display_text when present" do
      total = UcpMcp::Total.new(type: "tax", amount: 50, display_text: "Sales Tax")
      expect(total.to_wire_h).to eq({ "type" => "tax", "amount" => 50, "display_text" => "Sales Tax" })
    end
  end

  describe UcpMcp::Item do
    it "holds product identity for a line item" do
      item = UcpMcp::Item.new(id: "prod_1", title: "Cold Brew", price: 500)
      expect(item.to_wire_h).to eq({ "id" => "prod_1", "title" => "Cold Brew", "price" => 500 })
    end
  end

  describe UcpMcp::LineItem do
    it "holds an item/quantity/totals triple, matching the real wire shape" do
      item = UcpMcp::Item.new(id: "prod_1", title: "Cold Brew", price: 500)
      totals = [UcpMcp::Total.new(type: "subtotal", amount: 1000), UcpMcp::Total.new(type: "total", amount: 1000)]
      line_item = UcpMcp::LineItem.new(id: "li_1", item: item, quantity: 2, totals: totals)

      expect(line_item.quantity).to eq(2)
      expect(line_item.to_wire_h).to eq(
        { "id" => "li_1", "item" => { "id" => "prod_1", "title" => "Cold Brew", "price" => 500 },
          "quantity" => 2,
          "totals" => [{ "type" => "subtotal", "amount" => 1000 }, { "type" => "total", "amount" => 1000 }] }
      )
    end
  end

  describe UcpMcp::Cart do
    it "holds line items and a totals array, with no ucp envelope of its own" do
      cart = UcpMcp::Cart.new(id: "cart_1", line_items: [], currency: "USD", totals: [])
      expect(cart.line_items).to eq([])
      expect(cart.to_wire_h).not_to have_key("ucp")
    end
  end

  describe UcpMcp::Checkout do
    it "holds checkout state with the real status enum and required links array" do
      checkout = UcpMcp::Checkout.new(id: "chk_1", status: "incomplete", line_items: [], currency: "USD",
                                      totals: [], links: [])
      expect(checkout.status).to eq("incomplete")
      expect(checkout.to_wire_h["links"]).to eq([])
    end
  end

  describe UcpMcp::Order do
    it "holds order state with a totals array" do
      total = UcpMcp::Total.new(type: "total", amount: 500)
      order = UcpMcp::Order.new(id: "ord_1", status: "placed", line_items: [],
                                currency: "USD", totals: [total], placed_at: "2026-07-23T00:00:00Z")
      expect(order.status).to eq("placed")
      expect(order.to_wire_h["totals"]).to eq([{ "type" => "total", "amount" => 500 }])
    end
  end

  describe UcpMcp::Identity do
    it "holds a linked identity" do
      identity = UcpMcp::Identity.new(subject: "sub_1", email: "a@example.com", linked_at: "2026-07-23T00:00:00Z")
      expect(identity.email).to eq("a@example.com")
    end
  end
end
