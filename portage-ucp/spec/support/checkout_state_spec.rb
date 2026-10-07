require "spec_helper"
require "stringio"

RSpec.describe Portage::Ucp::Support::CheckoutState do
  let(:adapter_class) do
    Class.new do
      include Portage::Ucp::Support::CheckoutState

      def status_of(checkout_id) = checkout_status(checkout_id)
      def mark(checkout_id, status) = record_checkout_status(checkout_id, status)
      def link(order_id, checkout_id) = record_order_checkout(order_id, checkout_id)
      def origin_of(order_id) = checkout_id_for(order_id)
    end
  end
  let(:adapter) { adapter_class.new }

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

  describe "the optional platform_checkout_order hook (design-log §55)" do
    let(:order) do
      Portage::Ucp::Order.new(
        id: "order-9", checkout_id: "", permalink_url: "https://shop.example/orders/9",
        line_items: [Portage::Ucp::OrderLineItem.new(
          id: "li-1", item: Portage::Ucp::Item.new(id: "sku-1", title: "Lamp", price: 500),
          quantity: { original: 2, total: 2, fulfilled: 0 }, totals: Portage::Ucp::Support::Totals.line(1000),
          status: "processing"
        )],
        fulfillment: Portage::Ucp::Fulfillment.new, currency: "USD",
        totals: Portage::Ucp::Support::Totals.summary(subtotal: 1000, total: 1000)
      )
    end
    let(:hooked_class) do
      Class.new(adapter_class) do
        attr_accessor :platform_answer, :lookups

        def order_of(checkout_id) = checkout_order(checkout_id)
        def rebuilt(checkout_id) = checkout_from_platform_order(checkout_id)

        private

        def platform_checkout_order(_checkout_id)
          self.lookups = (lookups || 0) + 1
          platform_answer.respond_to?(:call) ? platform_answer.call : platform_answer
        end
      end
    end
    let(:fresh) { hooked_class.new }

    it "reports completed plus the order for an unknown checkout the platform says became an order" do
      fresh.platform_answer = order
      expect(fresh.status_of("cart-1")).to eq("completed")
      expect(fresh.order_of("cart-1").to_wire_h).to eq("id" => "order-9",
                                                       "permalink_url" => "https://shop.example/orders/9")
      expect(fresh.origin_of("order-9")).to eq("cart-1")
    end

    it "caches a found order, so the platform is asked once per process" do
      fresh.platform_answer = order
      2.times { fresh.status_of("cart-1") }
      expect(fresh.lookups).to eq(1)
    end

    it "keeps incomplete when the platform has no order, and asks again next time" do
      fresh.platform_answer = nil
      2.times { expect(fresh.status_of("cart-1")).to eq("incomplete") }
      expect(fresh.lookups).to eq(2)
      expect(fresh.order_of("cart-1")).to be_nil
    end

    it "falls back to incomplete when the lookup raises" do
      fresh.platform_answer = -> { raise IOError, "connection reset" }
      expect(fresh.status_of("cart-1")).to eq("incomplete")
    end

    it "never asks the platform about a checkout this process already tracks" do
      fresh.mark("cart-1", "incomplete")
      fresh.platform_answer = order
      expect(fresh.status_of("cart-1")).to eq("incomplete")
      expect(fresh.lookups).to be_nil
    end

    it "rebuilds a completed checkout from the order when the cart itself is gone" do
      fresh.platform_answer = order
      wire = fresh.rebuilt("cart-1").to_wire_h
      expect(wire).to include("id" => "cart-1", "status" => "completed", "currency" => "USD",
                              "order" => { "id" => "order-9", "permalink_url" => "https://shop.example/orders/9" })
      expect(wire["line_items"].first).to include("quantity" => 2, "item" => include("id" => "sku-1"))
      expect(Portage::Ucp::Support::Totals.amount(wire["totals"])).to eq(1000)
    end

    it "reports nothing for a gone cart with no order: a vanished cart is never a completion" do
      fresh.platform_answer = nil
      expect(fresh.rebuilt("cart-1")).to be_nil
    end

    it "keeps the default incomplete for an adapter without the hook" do
      expect(adapter.send(:checkout_from_platform_order, "cart-1")).to be_nil
      expect(adapter.status_of("cart-1")).to eq("incomplete")
    end
  end

  it "doesn't log when nothing has set observability via .with_observability (§23)" do
    expect { adapter.mark("cart-1", "completed") }.not_to raise_error
  end

  it "emits a checkout_state_transition event once .with_observability is active (§12, §23)" do
    io = StringIO.new
    logger = Logger.new(io).tap { |l| l.formatter = proc { |_severity, _time, _progname, msg| "#{msg}\n" } }

    described_class.with_observability(adapter, logger, "corr-abc") do
      adapter.mark("cart-1", "completed")
    end

    logged = JSON.parse(io.string.lines.last)
    expect(logged).to include("event" => "checkout_state_transition", "checkout_id" => "cart-1",
                              "status" => "completed", "correlation_id" => "corr-abc")
  end

  it "restores the previous observability state after the block returns" do
    io = StringIO.new
    logger = Logger.new(io).tap { |l| l.formatter = proc { |_severity, _time, _progname, msg| "#{msg}\n" } }

    described_class.with_observability(adapter, logger, "corr-1") { adapter.mark("cart-1", "completed") }
    adapter.mark("cart-2", "completed")

    events = io.string.lines.map { |line| JSON.parse(line) }
    expect(events.size).to eq(1)
    expect(events.first["checkout_id"]).to eq("cart-1")
  end

  it "doesn't let one adapter's observability leak onto a different adapter (per-object_id key)" do
    io = StringIO.new
    logger = Logger.new(io).tap { |l| l.formatter = proc { |_severity, _time, _progname, msg| "#{msg}\n" } }
    other_adapter = adapter_class.new

    described_class.with_observability(adapter, logger, "corr-mine") do
      other_adapter.mark("cart-1", "completed")
    end

    expect(io.string).to be_empty
  end

  it "keeps two concurrent .with_observability calls on the same adapter from clobbering each other's id" do
    io = StringIO.new
    mutex = Mutex.new
    logger = Logger.new(io).tap { |l| l.formatter = proc { |_severity, _time, _progname, msg| "#{msg}\n" } }

    threads = %w[corr-a corr-b].map do |correlation_id|
      Thread.new do
        described_class.with_observability(adapter, logger, correlation_id) do
          sleep(correlation_id == "corr-a" ? 0.02 : 0.0)
          mutex.synchronize { adapter.mark(correlation_id, "completed") }
        end
      end
    end
    threads.each(&:join)

    logged_pairs = io.string.lines.map { |line| JSON.parse(line) }
                                  .map { |h| [h["checkout_id"], h["correlation_id"]] }
    expect(logged_pairs).to contain_exactly(%w[corr-a corr-a], %w[corr-b corr-b])
  end
end
