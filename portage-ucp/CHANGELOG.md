# Changelog

All notable changes to this project are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.0.0/); this project is
pre-1.0, so APIs may still shift between minor versions.

## [0.3.0] - 2026-08-27

- `Portage::Ucp::Support::Retry` (`lib/portage/ucp/support/retry.rb`) —
  bounded retry with backoff for adapters, plus normalized conflict/throttle
  errors on `Support::ApiError` so a caller can distinguish "retry this" from
  "don't."
- `Portage::Ucp::Support::SessionLock` (`lib/portage/ucp/support/session_lock.rb`)
  — serializes per-cart/checkout mutations against a single upstream session,
  used by the Shopify and Wix adapters to stop concurrent cart writes from
  racing the same checkout.
- `Support::Idempotency` is now thread-safe under concurrent duplicate calls
  — the dedup table write was not atomic, so two requests with the same
  idempotency key arriving together could both miss the cache and both hit
  the adapter.
- Conformance kit: the repeated-idempotency-key example no longer passes on
  output equality alone. An adapter wired to a fixed-response test double
  returns identical output whether or not it deduped, so the example now also
  asserts the key reached `Support::Idempotency`'s dedup table when the
  adapter includes that module, and `warn`s (rather than silently passing)
  when it doesn't.

- `Portage::Ucp::ReferenceAdapter` (`lib/portage/ucp/reference_adapter.rb`) —
  the in-memory `Adapter` roadmap §8 step 1 called for and design-log §17
  flagged as missing outside `spec/support/fake_adapter.rb`, ships with the
  gem now. Implements every capability including
  `discount_codes_supported?`/`fulfillment_supported?`/`link_identity` — the
  first adapter in this repo to back identity linking at all.
- `Portage::Ucp::RSpec`/`portage/ucp/rspec.rb` — the adapter conformance kit
  design-log §17 called "the missing piece that turns 'any backend that
  implements Adapter' from a README claim into something checked": an
  `it_behaves_like "a portage adapter"` shared-examples suite checking the
  contract's behavioral guarantees (idempotency dedup, the PAN guard,
  schema-conformant wire output, `OutOfStockError` on a stale-stock line) —
  not loaded by `require "portage/ucp"`, opt-in via `require
  "portage/ucp/rspec"` since it pulls in RSpec itself. Exercised against
  `ReferenceAdapter` in this gem's own suite
  (`spec/reference_adapter_conformance_spec.rb`); wired into each adapter
  gem's own spec suite (`spec/portage/ucp/<platform>/conformance_spec.rb`)
  as follow-up.
- Conformance kit: `existing_variant_id` alongside `existing_product_id`, for
  adapters (Shopify) where a catalog lookup id and a cart line-item id are
  different GIDs. Defaults to `existing_product_id`, so every other adapter
  is unaffected.
- `search_catalog`/`get_product` output is schema-wrapped like every other
  capability now — previously returned a bare array/`Product` with no
  `to_wire_h`, so the dispatcher's schema-wrap never touched it and nothing
  caught it drifting from `catalog_search.json`/`catalog_lookup.json`.

## [0.2.0] - 2026-08-21

- `Portage::Ucp::OutOfStockError` — the contract for `#complete_checkout`
  (design-log §16 "Stock/availability going stale") now documents that
  adapters should raise it when the platform rejects completion over a
  no-longer-available line item, instead of re-checking with a separate call
  agents could forget to make.
- `Adapter#cancel_order`, `#request_return`, `#refund_order` — a gem-side
  extension of `dev.ucp.shopping.order` (design-log §16 "Order changes"),
  since the real UCP spec's order lifecycle is get-only. Each returns the
  updated `Order`, with the change recorded as an appended
  `Portage::Ucp::Adjustment`.
- `Capability#predicate` — a minimal escape hatch for extensions that add
  fields rather than actions (`dev.ucp.shopping.discount`,
  `dev.ucp.shopping.fulfillment`): a capability can name an adapter method
  instead of an action set, and `#advertised_for?` asks it directly.
  `create_cart`/`update_cart`/`create_checkout`/`update_checkout` gain an
  optional `discount_codes:` param defaulting to `nil` (not `[]`), so "not
  mentioned" and "clear the codes" stay distinguishable.
- `dev.ucp.shopping.fulfillment` — the vendored extension for picking a
  shipping method/rate or pickup location during checkout. New value objects
  `PostalAddress`, `ShippingDestination`, `RetailLocation`,
  `FulfillmentOption`, `FulfillmentGroup`, `FulfillmentMethod`, and the
  `CheckoutFulfillment` container (named apart from `Fulfillment`, which
  Order's post-purchase container already owns — see design-log).

## [0.1.0] - 2026-08-14

- Initial pre-release. Protocol-only core: `Adapter` contract, capability
  registry, manifest builder, MCP server wrapper, offline `SchemaValidator`,
  `portage-ucp-check` CLI.
- `Portage::Ucp::Support`: shared building blocks the adapter gems mix in
  (money conversion, totals shapes, idempotency dedup, checkout-state
  tracking, `ApiError`, 404-to-nil reads, Net::HTTP JSON client, OAuth token
  exchange). Not used by the core gem's own request path.
