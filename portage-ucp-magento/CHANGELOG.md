# Changelog

All notable changes to this project are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.0.0/); this project is
pre-1.0, so APIs may still shift between minor versions.

## [Unreleased]

- **Fixed: a checkout the shopper paid for in the browser now reads as `completed` from a new process.** Status lived only in the creating process, so `portage orders reconcile` always saw `incomplete`, or an error once Magento deactivated the quote. `#get_checkout` now resolves the masked cart id to its quote id (`GET /V1/guest-carts/{cartId}`, which still answers for an inactive quote), searches admin orders by `quote_id`, and reports `completed` with the `order` confirmation when one is `processing`, `complete` or `closed`, rebuilding the checkout from that order if the cart can no longer be read. The order search needs `admin_token`. No order, or a failed lookup, keeps `incomplete`; a cart that 404s with no order now returns nil instead of raising `ApiError`, like the other reads. Needs the `portage-ucp` release with the `CheckoutState` platform hook. Patch-level.

## [0.2.0] - 2026-10-05

- **Removed the unused `Client#admin_post`.** Nothing in the gem called it. It was public on the client class, so this is **breaking** for any caller using it directly; minor-level for a pre-1.0 gem.

- **Removed `Mapper.money`.** It was a one-line pass-through to `Support::Amounts.money` that nothing in the gem called. It is a public module function, so this is **breaking** for any caller using it directly; minor-level for a pre-1.0 gem.

## [0.1.5] - 2026-09-29

- Fixes a `NoMethodError` at launch: `exe/portage-ucp-magento` handed the
  server `Server.build(adapter:).start`, but `Server.build` returns a plain
  `MCP::Server` (mcp gem 0.25.0), which has no `#start` — only
  `MCP::Server::Transports::StdioTransport#open` reads stdio frames. The exe
  now calls that directly, matching `portage-ucp-etsy`'s exe. Adds
  `spec/portage/ucp/magento/exe_spec.rb`, which runs the exe as a real
  subprocess and pipes it a JSON-RPC `initialize` + `tools/list` handshake
  to prove it actually starts and answers requests.

## [0.1.4] - 2026-09-17

- No behavior change — widens the `portage-ucp` dependency pin to `~> 0.8`
  so this gem can install alongside `portage-ucp` 0.8.0 (the `~> 0.7` pin
  published with 0.1.3 is pessimistic and excludes it).

## [0.1.3] - 2026-09-16

- No behavior change — 0.1.2 was built and pushed with `gem build` run from
  the workspace root instead of this gem's own directory, so `spec.files =
  Dir[...]` resolved against the wrong working directory and packaged an
  empty gem. 0.1.2 has been yanked; 0.1.3 repackages the exact same 0.1.2
  code correctly.

## [0.1.2] - 2026-09-16

- No behavior change — widens the `portage-ucp` dependency pin to `~> 0.7`
  so this gem can install alongside `portage-ucp` 0.7.0 (the pessimistic
  `~> 0.6` pin published with 0.1.1 excludes it).

## [0.1.1] - 2026-09-15

- **Fix:** `Mapper.product`/`.variants` built `Portage::Ucp::Product`/`Variant`
  with the pre-schema `price:`/`available:` keywords core dropped when
  `dev.ucp.shopping.catalog` became schema-conformant — every real
  `search_catalog`/`get_product` call raised `ArgumentError: missing keyword:
  :price_range`. Now builds `Description`/`Price`/`PriceRange` objects and a
  real `Variant` array, matching `Shopify`/`Wix`'s mappers.
- **Fix:** `Adapter#search_catalog` returned a bare `Array<Product>` instead
  of the `CatalogSearchResult` the `Adapter` contract documents — its wire
  form has no `products` wrapper, so it never validated against UCP's
  `catalog_search.json` response schema.
- **Fix:** `Adapter#get_product` returned a bare `Product` instead of
  `ProductDetail`, so its wire form had no `product` wrapper either, for the
  same reason as `search_catalog` above.

## [0.1.0] - Unreleased

- Initial pre-release. Magento/Adobe Commerce adapter against the REST v1 API
  (admin-token catalog/order, anonymous guest-cart cart/checkout).
