require "spec_helper"
require "stringio"

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

  it "doesn't log when nothing has set ucp_observability (§23)" do
    expect { adapter.mark("cart-1", "completed") }.not_to raise_error
  end

  it "emits a checkout_state_transition event once ucp_observability= has been set (§12, §23)" do
    io = StringIO.new
    logger = Logger.new(io).tap { |l| l.formatter = proc { |_severity, _time, _progname, msg| "#{msg}\n" } }
    adapter.ucp_observability = [logger, "corr-abc"]

    adapter.mark("cart-1", "completed")

    logged = JSON.parse(io.string.lines.last)
    expect(logged).to include("event" => "checkout_state_transition", "checkout_id" => "cart-1",
                              "status" => "completed", "correlation_id" => "corr-abc")
  end
end
