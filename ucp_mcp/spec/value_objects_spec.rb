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

  describe UcpMcp::LineItem do
    it "holds a product/quantity/price triple" do
      unit_price = UcpMcp::Money.new(amount_minor: 500, currency: "USD")
      total = UcpMcp::Money.new(amount_minor: 1000, currency: "USD")
      item = UcpMcp::LineItem.new(id: "li_1", product_id: "prod_1", quantity: 2,
                                  unit_price: unit_price, total: total)
      expect(item.quantity).to eq(2)
      expect(item.total.amount_minor).to eq(1000)
    end
  end

  describe UcpMcp::Cart do
    it "holds line items and a subtotal" do
      cart = UcpMcp::Cart.new(id: "cart_1", line_items: [],
                              subtotal: UcpMcp::Money.new(amount_minor: 0, currency: "USD"), currency: "USD")
      expect(cart.line_items).to eq([])
    end
  end

  describe UcpMcp::Checkout do
    it "holds checkout state" do
      zero = UcpMcp::Money.new(amount_minor: 0, currency: "USD")
      checkout = UcpMcp::Checkout.new(id: "chk_1", status: "pending", line_items: [],
                                      subtotal: zero, tax: zero, total: zero,
                                      currency: "USD", locale: "en-US",
                                      available_payment_handlers: [])
      expect(checkout.status).to eq("pending")
    end
  end

  describe UcpMcp::Order do
    it "holds order state" do
      total = UcpMcp::Money.new(amount_minor: 500, currency: "USD")
      order = UcpMcp::Order.new(id: "ord_1", status: "placed", line_items: [],
                                total: total, currency: "USD", placed_at: "2026-07-23T00:00:00Z")
      expect(order.status).to eq("placed")
    end
  end

  describe UcpMcp::Identity do
    it "holds a linked identity" do
      identity = UcpMcp::Identity.new(subject: "sub_1", email: "a@example.com", linked_at: "2026-07-23T00:00:00Z")
      expect(identity.email).to eq("a@example.com")
    end
  end
end
