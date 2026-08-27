require "portage/ucp"

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
  let(:dispatcher) { Portage::Ucp::Dispatcher.new(adapter: adapter) }
  let(:schema_validator) { Portage::Ucp::SchemaValidator.new }
  let(:conformance_idempotency_key) { "conformance-#{object_id}-#{rand(1_000_000)}" }

  def checkout_capability_advertised?
    Portage::Ucp::RSpec.advertised?(adapter, "dev.ucp.shopping.checkout")
  end

  def catalog_capability_advertised?
    Portage::Ucp::RSpec.advertised?(adapter, "dev.ucp.shopping.catalog")
  end

  def create_conformance_checkout(idempotency_key: conformance_idempotency_key)
    dispatcher.call(
      capability: "dev.ucp.shopping.checkout", action: "create_checkout",
      arguments: { line_items: [{ product_id: existing_product_id, quantity: 1 }],
                   idempotency_key: idempotency_key }
    )
  end

  it "produces a create_checkout response that validates against UCP's own checkout schema" do
    skip "adapter does not advertise dev.ucp.shopping.checkout" unless checkout_capability_advertised?

    response = create_conformance_checkout
    errors = schema_validator.errors_for("schemas/shopping/checkout.json", response[:structuredContent])

    expect(errors).to eq([]), "create_checkout's response doesn't validate: #{errors.join('; ')}"
  end

  # The core gem's own dedup table, when the adapter uses it (every bundled
  # adapter includes `Support::Idempotency`). nil for an adapter that dedupes
  # some other way — see the example below for why that costs it a check.
  def conformance_dedup_table
    return nil unless adapter.is_a?(Portage::Ucp::Support::Idempotency)

    adapter.instance_variable_get(:@idempotency_results)
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
end
