require "spec_helper"
require "portage/ucp/rspec"
require "support/product_factory"
require "stringio"

# Runs the conformance kit against the gem's own ReferenceAdapter — proves
# both that the shipped reference implementation actually satisfies the
# contract, and that the kit itself (portage/ucp/rspec.rb) is wired up
# correctly, before any third-party adapter gem depends on it.
RSpec.describe Portage::Ucp::ReferenceAdapter do
  let(:adapter) { described_class.new }
  let(:existing_product_id) { "prod_1" }
  let(:out_of_stock_product_id) { "oos_1" }

  before do
    adapter.seed_product(ProductFactory.build(id: "prod_1", title: "Cold Brew", price_minor: 500))
    adapter.seed_product(ProductFactory.build(id: "oos_1", title: "Sold Out Blend", price_minor: 700,
                                              available: false))
  end

  it_behaves_like "a portage adapter"

  it "advertises discount and fulfillment (both true) and identity (link_identity overridden)" do
    registry = Portage::Ucp::CapabilityRegistry.default
    advertised = registry.advertised(adapter).map(&:name)

    expect(advertised).to include("dev.ucp.shopping.discount", "dev.ucp.shopping.fulfillment",
                                  "dev.ucp.shopping.identity", "app.portage-ucp.payment_enrollment",
                                  "app.portage-ucp.payment_method", "app.portage-ucp.saved_address",
                                  "app.portage-ucp.shopper_data")
  end

  describe "#create_payment_enrollment / #get_payment_enrollment" do
    it "starts pending with a setup_url, then completes with an opaque token" do
      enrollment = adapter.create_payment_enrollment(idempotency_key: "enr-1")
      expect(enrollment.status).to eq("pending")
      expect(enrollment.setup_url).to match(%r{\Ahttps://})
      expect(enrollment.payment_token).to be_nil

      still_pending = adapter.get_payment_enrollment(enrollment_id: enrollment.id)
      expect(still_pending.status).to eq("pending")

      completed = adapter.get_payment_enrollment(enrollment_id: enrollment.id)
      expect(completed.status).to eq("complete")
      expect(completed.payment_token).to be_a(String)
      expect(completed.setup_url).to be_nil
    end

    it "returns nil for an unknown enrollment id" do
      expect(adapter.get_payment_enrollment(enrollment_id: "penr_nonexistent")).to be_nil
    end

    it "dedupes a repeated idempotency_key rather than starting a second enrollment" do
      first = adapter.create_payment_enrollment(idempotency_key: "enr-2")
      second = adapter.create_payment_enrollment(idempotency_key: "enr-2")

      expect(second.id).to eq(first.id)
    end

    it "never returns a raw PAN as the payment_token" do
      enrollment = adapter.create_payment_enrollment(idempotency_key: "enr-3")
      adapter.get_payment_enrollment(enrollment_id: enrollment.id)
      completed = adapter.get_payment_enrollment(enrollment_id: enrollment.id)

      expect { Portage::Ucp::PaymentTokenGuard.validate!(completed.payment_token) }.not_to raise_error
    end
  end

  describe "#reorder" do
    def place_order(product_id:, quantity: 1)
      checkout = adapter.create_checkout(line_items: [{ product_id: product_id, quantity: quantity }],
                                         idempotency_key: "chk-#{product_id}-#{rand(1_000_000)}")
      completed = adapter.complete_checkout(checkout_id: checkout.id, payment_token: "tok",
                                            idempotency_key: "cmp-#{product_id}-#{rand(1_000_000)}")
      completed.order.id
    end

    it "returns nil for an unknown order id" do
      expect(adapter.reorder(order_id: "ord_nonexistent", idempotency_key: "k1")).to be_nil
    end

    it "hydrates a cart from a still-purchasable order" do
      order_id = place_order(product_id: existing_product_id, quantity: 2)

      result = adapter.reorder(order_id: order_id, idempotency_key: "reorder-1")

      expect(result.unavailable_items).to eq([])
      expect(result.cart.line_items.map { |li| [li.item.title, li.quantity] }).to eq([["Cold Brew", 2]])
    end

    it "drops a line item whose product was discontinued since purchase, reporting why" do
      adapter.seed_product(ProductFactory.build(id: "prod_2", title: "Espresso", price_minor: 300))
      order_id = place_order(product_id: "prod_2")
      adapter.instance_variable_get(:@products).delete("prod_2")

      result = adapter.reorder(order_id: order_id, idempotency_key: "reorder-2")

      expect(result.cart.line_items).to eq([])
      expect(result.unavailable_items.map(&:title)).to eq(["Espresso"])
      expect(result.unavailable_items.first.reason).to eq("discontinued")
    end

    it "dedupes a repeated idempotency_key rather than hydrating a second cart" do
      order_id = place_order(product_id: existing_product_id)

      first = adapter.reorder(order_id: order_id, idempotency_key: "reorder-3")
      second = adapter.reorder(order_id: order_id, idempotency_key: "reorder-3")

      expect(second.cart.id).to eq(first.cart.id)
    end
  end

  it "links an oauth token to a stable identity" do
    first = adapter.link_identity(oauth_token: "tok_abc")
    second = adapter.link_identity(oauth_token: "tok_abc")

    expect(first).to eq(second)
    expect(first.subject).to match(/\Auser_[0-9a-f]{12}\z/)
  end

  # §23 step 3: Dispatcher threads its logger and a per-call correlation_id
  # onto the adapter (Support::CheckoutState.with_observability, scoped to
  # this call only) so a checkout_state_transition event carries the same id
  # as the tool_called event that triggered it, without checkout methods
  # taking a correlation_id: kwarg (a breaking change to the Adapter
  # contract).
  it "emits a checkout_state_transition event through the correlation id Dispatcher was given (§12, §23)" do
    io = StringIO.new
    logger = Logger.new(io).tap { |l| l.formatter = proc { |_severity, _time, _progname, msg| "#{msg}\n" } }
    dispatcher = Portage::Ucp::Dispatcher.new(adapter: adapter, logger: logger)

    dispatcher.call(capability: "dev.ucp.shopping.checkout", action: "create_checkout",
                    arguments: { line_items: [{ product_id: "prod_1", quantity: 1 }], idempotency_key: "k1" },
                    correlation_id: "corr-123")

    logged = JSON.parse(io.string.lines.last)
    expect(logged["event"]).to eq("checkout_state_transition")
    expect(logged["status"]).to eq("incomplete")
    expect(logged["correlation_id"]).to eq("corr-123")
  end

  describe "#save_payment_method / #list_payment_methods / #delete_payment_method" do
    it "saves and lists a payment method for the calling shopper" do
      ref = adapter.save_payment_method(oauth_token: "tok_a", payment_token: "tok", idempotency_key: "pm-1")

      expect(ref.psp_reference).to be_a(String)
      expect(adapter.list_payment_methods(oauth_token: "tok_a")).to eq([ref])
    end

    it "dedupes a repeated idempotency_key rather than saving a second reference" do
      first = adapter.save_payment_method(oauth_token: "tok_a", payment_token: "tok", idempotency_key: "pm-2")
      second = adapter.save_payment_method(oauth_token: "tok_a", payment_token: "tok", idempotency_key: "pm-2")

      expect(second.id).to eq(first.id)
    end

    it "never lets one shopper's oauth_token see another shopper's saved payment methods" do
      adapter.save_payment_method(oauth_token: "tok_a", payment_token: "tok", idempotency_key: "pm-3")

      expect(adapter.list_payment_methods(oauth_token: "tok_b")).to eq([])
    end

    it "deletes a payment method, returning false for an already-gone id" do
      ref = adapter.save_payment_method(oauth_token: "tok_a", payment_token: "tok", idempotency_key: "pm-4")

      expect(adapter.delete_payment_method(oauth_token: "tok_a", payment_method_id: ref.id,
                                           idempotency_key: "pm-4-del")).to be(true)
      expect(adapter.delete_payment_method(oauth_token: "tok_a", payment_method_id: ref.id,
                                           idempotency_key: "pm-4-del-2")).to be(false)
    end
  end

  describe "#save_address / #list_addresses / #delete_address" do
    let(:address) { Portage::Ucp::PostalAddress.new(postal_code: "94043") }

    it "saves and lists an address for the calling shopper" do
      saved = adapter.save_address(oauth_token: "tok_a", address: address, idempotency_key: "addr-1")

      expect(saved.address).to eq(address)
      expect(adapter.list_addresses(oauth_token: "tok_a")).to eq([saved])
    end

    it "never lets one shopper's oauth_token see another shopper's saved addresses" do
      adapter.save_address(oauth_token: "tok_a", address: address, idempotency_key: "addr-2")

      expect(adapter.list_addresses(oauth_token: "tok_b")).to eq([])
    end

    it "deletes an address, returning false for an already-gone id" do
      saved = adapter.save_address(oauth_token: "tok_a", address: address, idempotency_key: "addr-3")

      expect(adapter.delete_address(oauth_token: "tok_a", address_id: saved.id,
                                    idempotency_key: "addr-3-del")).to be(true)
      expect(adapter.delete_address(oauth_token: "tok_a", address_id: saved.id,
                                    idempotency_key: "addr-3-del-2")).to be(false)
    end
  end

  describe "#delete_shopper_data" do
    let(:address) { Portage::Ucp::PostalAddress.new(postal_code: "94043") }

    it "erases every payment method, address, and the linked identity for the subject" do
      adapter.save_payment_method(oauth_token: "tok_a", payment_token: "tok", idempotency_key: "sd-pm-1")
      adapter.save_address(oauth_token: "tok_a", address: address, idempotency_key: "sd-addr-1")

      erasure = adapter.delete_shopper_data(oauth_token: "tok_a", idempotency_key: "sd-1")

      expect(erasure.payment_methods_deleted).to eq(1)
      expect(erasure.addresses_deleted).to eq(1)
      expect(erasure.identity_unlinked).to be(true)
      expect(adapter.list_payment_methods(oauth_token: "tok_a")).to eq([])
      expect(adapter.list_addresses(oauth_token: "tok_a")).to eq([])
    end

    it "is safe to repeat, returning zero counts without raising" do
      adapter.delete_shopper_data(oauth_token: "tok_a", idempotency_key: "sd-2")

      second = adapter.delete_shopper_data(oauth_token: "tok_a", idempotency_key: "sd-3")

      expect(second.payment_methods_deleted).to eq(0)
      expect(second.addresses_deleted).to eq(0)
    end
  end
end
