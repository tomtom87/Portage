require "spec_helper"

RSpec.describe Portage::Ucp::Support::CheckoutState do
  let(:adapter) do
    Class.new do
      include Portage::Ucp::Support::CheckoutState

      def status_of(checkout_id) = checkout_status(checkout_id)
      def mark(checkout_id, status) = record_checkout_status(checkout_id, status)
      def link(order_id, checkout_id) = record_order_checkout(order_id, checkout_id)
      def origin_of(order_id) = checkout_id_for(order_id)
    end.new
  end

  it "reports an unknown checkout as incomplete rather than raising" do
    expect(adapter.status_of("gid://Cart/never-seen")).to eq("incomplete")
  end

  it "reports the last recorded status for a checkout" do
    adapter.mark("cart-1", "completed")
    expect(adapter.status_of("cart-1")).to eq("completed")
  end

  it "tracks statuses per checkout" do
    adapter.mark("cart-1", "canceled")
    adapter.mark("cart-2", "completed")
    expect([adapter.status_of("cart-1"), adapter.status_of("cart-2")]).to eq(%w[canceled completed])
  end

  it "reports a blank checkout_id for an order it didn't complete" do
    expect(adapter.origin_of("order-1")).to eq("")
  end

  it "links an order back to the checkout that produced it" do
    adapter.link("order-1", "cart-1")
    expect(adapter.origin_of("order-1")).to eq("cart-1")
  end

  it "keys orders by string, so an integer id from a JSON body still resolves" do
    adapter.link(123, "cart-1")
    expect(adapter.origin_of("123")).to eq("cart-1")
  end
end
