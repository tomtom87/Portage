# Changelog

All notable changes to this project are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.0.0/); this project is
pre-1.0, so APIs may still shift between minor versions.

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
