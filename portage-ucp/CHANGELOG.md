# Changelog

All notable changes to this project are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.0.0/); this project is
pre-1.0, so APIs may still shift between minor versions.

## [Unreleased]

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

## [0.1.0] - Unreleased

- Initial pre-release. Protocol-only core: `Adapter` contract, capability
  registry, manifest builder, MCP server wrapper, offline `SchemaValidator`,
  `portage-ucp-check` CLI.
- `Portage::Ucp::Support`: shared building blocks the adapter gems mix in
  (money conversion, totals shapes, idempotency dedup, checkout-state
  tracking, `ApiError`, 404-to-nil reads, Net::HTTP JSON client, OAuth token
  exchange). Not used by the core gem's own request path.
