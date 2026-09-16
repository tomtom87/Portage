# Changelog

All notable changes to this project are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.0.0/); this project is
pre-1.0, so APIs may still shift between minor versions.

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

- Initial pre-release. BigCommerce adapter against the v3 Catalog/Carts/
  Checkouts APIs and v2 Orders API.
