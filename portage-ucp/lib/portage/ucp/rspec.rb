require "portage/ucp"
require "tmpdir"

module Portage
  module Ucp
    # Adapter conformance kit — design-log §17: "Nothing currently checks a
    # third-party Adapter against the contract before its capability shows up
    # in a manifest." `SchemaValidator` (see README, "Spec conformance")
    # checks wire *shape*; this checks the behavioral guarantees §9 promises
    # that schema-valid output can still violate — idempotency not actually
    # deduped, a raw PAN reaching the adapter, a capability advertised whose
    # own output doesn't round-trip through the schema it claims to speak.
    #
    # Not loaded by `require "portage/ucp"` — this pulls in RSpec itself,
    # which the core gem otherwise has zero runtime dependency on (only a
    # development one, per its own README). An adapter author's own spec
    # suite opts in explicitly:
    #
    #   require "portage/ucp/rspec"
    #
    #   RSpec.describe MyAdapter do
    #     it_behaves_like "a portage adapter" do
    #       let(:adapter) { MyAdapter.new(client: my_test_client) }
    #       let(:existing_product_id) { "known-good-product-id" }
    #       # optional — only needed when a purchasable line item is a
    #       # *different* id than the catalog product id (Shopify: a
    #       # ProductVariant GID vs. the parent Product GID). Defaults to
    #       # existing_product_id, which is correct for any backend where
    #       # "the product" and "the thing you add to a cart" share one id.
    #       # let(:existing_variant_id) { "known-good-purchasable-id" }
    #       # optional — enables the out-of-stock example:
    #       # let(:out_of_stock_product_id) { "known-sold-out-product-id" }
    #     end
    #   end
    #
    # `existing_product_id` must resolve to a real, in-stock, purchasable
    # product against whatever backend `adapter` is wired to (a live
    # sandbox store, or webmock/VCR stubs — this kit doesn't care which).
    # Every example below skips itself when the adapter under test doesn't
    # advertise the capability it needs, so a catalog/cart-only adapter
    # (§16's Etsy/Instagram shape) still runs the kit cleanly.
    module RSpec
      module_function

      def advertised?(adapter, capability_name)
        capability = Portage::Ucp::CapabilityRegistry.default.find(capability_name)
        capability&.advertised_for?(adapter)
      end
    end
  end
end

RSpec.shared_examples "a portage adapter" do
  # A conformance suite runs against a real adapter gem's own spec suite —
  # give it its own tmp-scoped transaction log rather than defaulting the
  # Dispatcher to the real `~/.portage/transactions.json` every adapter's
  # test run would otherwise write to.
  let(:conformance_transaction_log) do
    Portage::Ucp::Support::TransactionLog.new(path: File.join(Dir.mktmpdir, "transactions.json"))
  end
  # Same reasoning as `conformance_transaction_log` — an unconfigured Policy
  # (no file at this tmp path) is permissive, so this doesn't change what the
  # kit exercises, it just keeps an adapter gem's conformance run from
  # reading and being affected by the real `~/.portage/policy.json`.
  let(:conformance_policy) { Portage::Ucp::Policy.new(path: File.join(Dir.mktmpdir, "policy.json")) }
  # A conformance run isn't exercising Phase 3 confirmation, and the real
  # default (Confirmer::Terminal) would block every run on stdin — auto-
  # approve so `complete_checkout` examples complete unattended.
  let(:conformance_confirmer) { Portage::Ucp::Confirmer::AutoApprove.new }
  let(:dispatcher) do
    Portage::Ucp::Dispatcher.new(adapter: adapter, transaction_log: conformance_transaction_log,
                                 policy: conformance_policy, confirmer: conformance_confirmer)
  end
  let(:schema_validator) { Portage::Ucp::SchemaValidator.new }
  let(:conformance_idempotency_key) { "conformance-#{object_id}-#{rand(1_000_000)}" }
  let(:existing_variant_id) { existing_product_id }

  def checkout_capability_advertised?
    Portage::Ucp::RSpec.advertised?(adapter, "dev.ucp.shopping.checkout")
  end

  def catalog_capability_advertised?
    Portage::Ucp::RSpec.advertised?(adapter, "dev.ucp.shopping.catalog")
  end

  def create_conformance_checkout(idempotency_key: conformance_idempotency_key)
    dispatcher.call(
      capability: "dev.ucp.shopping.checkout", action: "create_checkout",
      arguments: { line_items: [{ product_id: existing_variant_id, quantity: 1 }],
                   idempotency_key: idempotency_key }
    )
  end

  it "produces a create_checkout response that validates against UCP's own checkout schema" do
    skip "adapter does not advertise dev.ucp.shopping.checkout" unless checkout_capability_advertised?

    response = create_conformance_checkout
    errors = schema_validator.errors_for("schemas/shopping/checkout.json", response[:structuredContent])

    expect(errors).to eq([]), "create_checkout's response doesn't validate: #{errors.join('; ')}"
  end

  # The core gem's own dedup store, when the adapter uses it (every bundled
  # adapter includes `Support::Idempotency`). nil for an adapter that dedupes
  # some other way — see the example below for why that costs it a check.
  # `dedup`/the store accessor are adapter-internal (private), so this reaches
  # past that the same way `instance_variable_get` used to — it's the
  # conformance kit checking the guarantee actually held, not a public API.
  def conformance_dedup_table
    return nil unless adapter.is_a?(Portage::Ucp::Support::Idempotency)

    adapter.send(:idempotency_store)
  end

  it "dedupes a repeated idempotency_key on create_checkout rather than re-running the mutation (§9a)" do
    skip "adapter does not advertise dev.ucp.shopping.checkout" unless checkout_capability_advertised?

    first = create_conformance_checkout
    second = create_conformance_checkout

    expect(second[:structuredContent]).to eq(first[:structuredContent]),
                                          "a repeated idempotency_key produced a different result — " \
                                          "the adapter isn't deduping mutating calls per §9a"

    # Equal output is necessary but nowhere near sufficient, and this is the
    # trap §17 named: an adapter wired to webmock/VCR stubs that answer every
    # request with one fixed response returns identical output whether or not
    # it deduped anything, so the assertion above passes for the wrong reason
    # on exactly the test setup an adapter author is most likely to write.
    # When the adapter uses `Support::Idempotency`, check the table itself —
    # an adapter that never deduped has no entry under the key at all.
    table = conformance_dedup_table
    if table.nil?
      warn "[portage conformance] #{adapter.class} doesn't include " \
           "Portage::Ucp::Support::Idempotency, so dedup was only checked by output equality — " \
           "which a fixed-response test double satisfies without deduping. Assert the dedup " \
           "yourself (e.g. `expect(stub).to have_been_requested.once`) in your own spec."
    else
      expect(table).to include(conformance_idempotency_key),
                       "create_checkout returned equal output for a repeated idempotency_key but recorded " \
                       "nothing in the dedup table — the second call re-ran the mutation and only looked " \
                       "deduped because the backend double answers every request identically (§9a)"
    end
  end

  it "produces a search_catalog response that validates against UCP's own catalog search schema" do
    skip "adapter does not advertise dev.ucp.shopping.catalog" unless catalog_capability_advertised?

    response = dispatcher.call(capability: "dev.ucp.shopping.catalog", action: "search_catalog",
                               arguments: { query: "", limit: 5 })
    errors = schema_validator.errors_for("schemas/shopping/catalog_search.json#/$defs/search_response",
                                         response[:structuredContent])

    expect(errors).to eq([]), "search_catalog's response doesn't validate: #{errors.join('; ')}"
  end

  it "produces a get_product response that validates against UCP's own catalog lookup schema" do
    skip "adapter does not advertise dev.ucp.shopping.catalog" unless catalog_capability_advertised?

    response = dispatcher.call(capability: "dev.ucp.shopping.catalog", action: "get_product",
                               arguments: { product_id: existing_product_id })
    errors = schema_validator.errors_for("schemas/shopping/catalog_lookup.json#/$defs/get_product_response",
                                         response[:structuredContent])

    expect(errors).to eq([]), "get_product's response doesn't validate: #{errors.join('; ')}"
  end

  it "never lets a raw, Luhn-valid PAN reach the adapter's complete_checkout (§9's PCI boundary)" do
    skip "adapter does not advertise dev.ucp.shopping.checkout" unless checkout_capability_advertised?

    checkout_id = create_conformance_checkout[:structuredContent]["id"]
    expect(adapter).not_to receive(:complete_checkout)

    expect do
      dispatcher.call(capability: "dev.ucp.shopping.checkout", action: "complete_checkout",
                      arguments: { checkout_id: checkout_id, payment_token: "4242424242424242",
                                   idempotency_key: "#{conformance_idempotency_key}-complete" })
    end.to raise_error(Portage::Ucp::RawPanRejectedError)
  end

  it "raises Portage::Ucp::OutOfStockError from complete_checkout for a line that's gone out of stock" do
    skip "no out_of_stock_product_id given — this example is opt-in" unless respond_to?(:out_of_stock_product_id)
    skip "adapter does not advertise dev.ucp.shopping.checkout" unless checkout_capability_advertised?

    checkout = dispatcher.call(
      capability: "dev.ucp.shopping.checkout", action: "create_checkout",
      arguments: { line_items: [{ product_id: out_of_stock_product_id, quantity: 1 }],
                   idempotency_key: "#{conformance_idempotency_key}-oos" }
    )

    expect do
      dispatcher.call(capability: "dev.ucp.shopping.checkout", action: "complete_checkout",
                      arguments: { checkout_id: checkout[:structuredContent]["id"],
                                   payment_token: "sptk_conformance_test_token",
                                   idempotency_key: "#{conformance_idempotency_key}-oos-complete" })
    end.to raise_error(Portage::Ucp::OutOfStockError)
  end

  # app.portage-ucp.payment_enrollment (design-log §33/Phase B) — Portage
  # extension, no schemas/ counterpart to validate against, same posture as
  # payment_method/saved_address/shopper_data below. Dispatcher#call already
  # runs every create_payment_enrollment/get_payment_enrollment result
  # through PaymentEnrollmentGuard (dispatcher.rb), so an adapter that
  # returns a malformed enrollment fails these examples with
  # InvalidPaymentEnrollmentError, not a silent pass — this is the contract
  # a real PSP adapter must be held to before it's the only implementor,
  # same "cheap moment" framing as ReferenceAdapter today.
  it "produces create_payment_enrollment / get_payment_enrollment responses that satisfy the " \
     "payment-enrollment guard (§33)" do
    skip "adapter does not advertise app.portage-ucp.payment_enrollment" unless
      payment_enrollment_capability_advertised?

    created = dispatcher.call(capability: "app.portage-ucp.payment_enrollment", action: "create_payment_enrollment",
                              arguments: { idempotency_key: "#{conformance_idempotency_key}-penr" })

    expect do
      dispatcher.call(capability: "app.portage-ucp.payment_enrollment", action: "get_payment_enrollment",
                      arguments: { enrollment_id: created[:structuredContent]["id"] })
    end.not_to raise_error
  end

  # app.portage-ucp.payment_method / saved_address / shopper_data (§22 item
  # 7) — Portage extensions, no schemas/ counterpart to validate against, so
  # these examples check the behavioral guarantee §16 called out instead:
  # oauth_token: is the authorization boundary, not just a call parameter.
  let(:conformance_oauth_token) { "conformance-oauth-#{object_id}-#{rand(1_000_000)}" }
  let(:other_conformance_oauth_token) { "conformance-oauth-other-#{object_id}-#{rand(1_000_000)}" }

  def payment_enrollment_capability_advertised?
    Portage::Ucp::RSpec.advertised?(adapter, "app.portage-ucp.payment_enrollment")
  end

  def payment_method_capability_advertised?
    Portage::Ucp::RSpec.advertised?(adapter, "app.portage-ucp.payment_method")
  end

  def saved_address_capability_advertised?
    Portage::Ucp::RSpec.advertised?(adapter, "app.portage-ucp.saved_address")
  end

  def shopper_data_capability_advertised?
    Portage::Ucp::RSpec.advertised?(adapter, "app.portage-ucp.shopper_data")
  end

  it "saves, lists, and deletes a payment method scoped to the oauth_token that saved it" do
    skip "adapter does not advertise app.portage-ucp.payment_method" unless payment_method_capability_advertised?

    saved = dispatcher.call(
      capability: "app.portage-ucp.payment_method", action: "save_payment_method",
      arguments: { oauth_token: conformance_oauth_token, payment_token: "sptk_conformance_test_token",
                   idempotency_key: "#{conformance_idempotency_key}-pm" }
    )
    payment_method_id = saved[:structuredContent]["id"]

    listed = dispatcher.call(capability: "app.portage-ucp.payment_method", action: "list_payment_methods",
                             arguments: { oauth_token: conformance_oauth_token })
    expect(listed[:structuredContent].map { |ref| ref["id"] }).to include(payment_method_id)

    other = dispatcher.call(capability: "app.portage-ucp.payment_method", action: "list_payment_methods",
                            arguments: { oauth_token: other_conformance_oauth_token })
    expect(other[:structuredContent].map { |ref| ref["id"] }).not_to include(payment_method_id)

    dispatcher.call(capability: "app.portage-ucp.payment_method", action: "delete_payment_method",
                    arguments: { oauth_token: conformance_oauth_token, payment_method_id: payment_method_id,
                                 idempotency_key: "#{conformance_idempotency_key}-pm-del" })

    after_delete = dispatcher.call(capability: "app.portage-ucp.payment_method", action: "list_payment_methods",
                                   arguments: { oauth_token: conformance_oauth_token })
    expect(after_delete[:structuredContent].map { |ref| ref["id"] }).not_to include(payment_method_id)
  end

  it "never lets a raw, Luhn-valid PAN reach the adapter's save_payment_method (§9's PCI boundary)" do
    skip "adapter does not advertise app.portage-ucp.payment_method" unless payment_method_capability_advertised?

    expect do
      dispatcher.call(capability: "app.portage-ucp.payment_method", action: "save_payment_method",
                      arguments: { oauth_token: conformance_oauth_token, payment_token: "4242424242424242",
                                   idempotency_key: "#{conformance_idempotency_key}-pm-pan" })
    end.to raise_error(Portage::Ucp::RawPanRejectedError)
  end

  it "saves, lists, and deletes an address scoped to the oauth_token that saved it" do
    skip "adapter does not advertise app.portage-ucp.saved_address" unless saved_address_capability_advertised?

    saved = dispatcher.call(
      capability: "app.portage-ucp.saved_address", action: "save_address",
      arguments: { oauth_token: conformance_oauth_token, address: Portage::Ucp::PostalAddress.new(postal_code: "1"),
                   idempotency_key: "#{conformance_idempotency_key}-addr" }
    )
    address_id = saved[:structuredContent]["id"]

    listed = dispatcher.call(capability: "app.portage-ucp.saved_address", action: "list_addresses",
                             arguments: { oauth_token: conformance_oauth_token })
    expect(listed[:structuredContent].map { |addr| addr["id"] }).to include(address_id)

    other = dispatcher.call(capability: "app.portage-ucp.saved_address", action: "list_addresses",
                            arguments: { oauth_token: other_conformance_oauth_token })
    expect(other[:structuredContent].map { |addr| addr["id"] }).not_to include(address_id)

    dispatcher.call(capability: "app.portage-ucp.saved_address", action: "delete_address",
                    arguments: { oauth_token: conformance_oauth_token, address_id: address_id,
                                 idempotency_key: "#{conformance_idempotency_key}-addr-del" })

    after_delete = dispatcher.call(capability: "app.portage-ucp.saved_address", action: "list_addresses",
                                   arguments: { oauth_token: conformance_oauth_token })
    expect(after_delete[:structuredContent].map { |addr| addr["id"] }).not_to include(address_id)
  end

  it "erases every payment method and address for the subject, and is safe to repeat" do
    skip "adapter does not advertise app.portage-ucp.shopper_data" unless shopper_data_capability_advertised?

    if payment_method_capability_advertised?
      dispatcher.call(capability: "app.portage-ucp.payment_method", action: "save_payment_method",
                      arguments: { oauth_token: conformance_oauth_token, payment_token: "sptk_conformance_test_token",
                                   idempotency_key: "#{conformance_idempotency_key}-sd-pm" })
    end
    if saved_address_capability_advertised?
      dispatcher.call(capability: "app.portage-ucp.saved_address", action: "save_address",
                      arguments: { oauth_token: conformance_oauth_token,
                                   address: Portage::Ucp::PostalAddress.new(postal_code: "1"),
                                   idempotency_key: "#{conformance_idempotency_key}-sd-addr" })
    end

    erasure = dispatcher.call(capability: "app.portage-ucp.shopper_data", action: "delete_shopper_data",
                              arguments: { oauth_token: conformance_oauth_token,
                                           idempotency_key: "#{conformance_idempotency_key}-sd" })
    expect(erasure[:structuredContent]["payment_methods_deleted"]).to be >= 0
    expect(erasure[:structuredContent]["addresses_deleted"]).to be >= 0

    expect do
      dispatcher.call(capability: "app.portage-ucp.shopper_data", action: "delete_shopper_data",
                      arguments: { oauth_token: conformance_oauth_token,
                                   idempotency_key: "#{conformance_idempotency_key}-sd-2" })
    end.not_to raise_error
  end
end
