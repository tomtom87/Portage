## Writing your own adapter

```ruby
class MyAdapter < Portage::Ucp::Adapter
  def search_catalog(query:, limit:) = ...
  def get_product(product_id:) = ...
  def create_cart(line_items:, idempotency_key:) = ...
  # override only the capabilities you support — the rest stay unadvertised
end
```

See `Portage::Ucp::Adapter` for the full method contract (catalog, cart, checkout, order, identity linking, reorder), `Portage::Ucp::ReferenceAdapter` (ships with the core gem, `lib/portage/ucp/reference_adapter.rb`) for a complete in-memory implementation of every capability including discount/fulfillment/identity/reorder, and `portage-ucp-shopify`'s `Adapter` for a real one against a live commerce API.

`reorder` (`app.portage-ucp.reorder`) is a Portage-owned extension, not part of the UCP spec: it hydrates a `Cart` from a past order's line items, re-checking each item's current availability rather than replaying historical prices, and reports anything no longer purchasable via `ReorderResult#unavailable_items` instead of failing outright.

`payment_method` / `saved_address` / `shopper_data` (`app.portage-ucp.payment_method`, `app.portage-ucp.saved_address`, `app.portage-ucp.shopper_data`) are Portage-owned extensions too, shipped together: saved payment references and addresses, plus the erasure path that removes them (and the shopper's linked identity) in one call. `oauth_token:` is the authorization boundary on every method here, including the two `list_*` reads — see `Portage::Ucp::Adapter`'s doc comments on `save_payment_method` for why a bare `subject:` string would be a lookup vulnerability. `save_payment_method`'s `payment_token:` runs through the same `PaymentTokenGuard` Luhn/format check as `complete_checkout`, and `delete_shopper_data` is idempotent — safe to call again on an already-erased subject.

### Checking your adapter against the contract

`Portage::Ucp::SchemaValidator` (see [Spec conformance](#spec-conformance) below) checks that your `Adapter`'s output matches UCP's wire schemas, but schema-valid output can still violate the contract's behavioral guarantees — an idempotency key that isn't actually deduped, a raw PAN reaching your adapter, a capability that's advertised but doesn't round-trip through its own schema. The core gem ships a conformance kit, an RSpec shared-examples suite, for that:

```ruby
# spec/spec_helper.rb
require "portage/ucp/rspec"

# spec/my_adapter_spec.rb
RSpec.describe MyAdapter do
  it_behaves_like "a portage adapter" do
    let(:adapter) { MyAdapter.new(client: my_test_client) }
    let(:existing_product_id) { "known-good-product-id" } # real/stubbed, in-stock, purchasable
    # optional — enables the out-of-stock example:
    # let(:out_of_stock_product_id) { "known-sold-out-product-id" }
  end
end
```

Not loaded by `require "portage/ucp"` — it pulls in RSpec, which the core gem otherwise has zero runtime dependency on. Every example skips itself when your adapter doesn't advertise the capability it needs, so an adapter that only does catalog and checkout still runs it cleanly.

All seven bundled adapter gems run it against their real `Adapter` (`spec/portage/ucp/<platform>/conformance_spec.rb` in each), and `spec/reference_adapter_conformance_spec.rb` in the core gem runs it against `ReferenceAdapter` — so it's exercised by CI on every push, not just documented. One canned backend response per call the kit makes is enough for a stubbed adapter: the repeat-key example is answered from the in-process dedup table without a second HTTP call, and the PAN example is rejected inside `Dispatcher` before `complete_checkout` runs. Include `Portage::Ucp::Support::Idempotency` in your adapter (as every bundled one does) and the dedup example checks the table itself rather than just comparing the two calls' output — output equality alone is satisfied by any fixed-response test double, deduped or not.
