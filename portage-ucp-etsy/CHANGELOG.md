# Changelog

All notable changes to this project are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.0.0/); this project is
pre-1.0, so APIs may still shift between minor versions.

## [Unreleased]

- **Fix:** this gem had no `exe/` or `examples/`, unlike every other adapter
  in this project (`portage-ucp-shopify`/`-wix`/`-woocommerce`/
  `-bigcommerce`/`-magento`) — there was no way to point an MCP client at a
  `command` for Etsy without hand-writing the `Client`/`Adapter`/
  `Server.build` wiring yourself. Adds `exe/portage-ucp-etsy` (reads
  `ETSY_ACCESS_TOKEN`/`ETSY_API_KEY`/`ETSY_SHOP_ID`, honors `PORTAGE_UCP_CONFIG`
  the same `-r`-a-file way the other exes do) and `examples/portage_ucp.rb`
  (a copy-paste `PORTAGE_UCP_CONFIG` starting point).

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

- Initial pre-release. Etsy adapter against Open API v3 — catalog and order
  real, checkout redirect-link only (no cart/checkout endpoint in Etsy's
  public API).
