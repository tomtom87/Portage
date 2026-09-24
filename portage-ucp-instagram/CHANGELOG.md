# Changelog

All notable changes to this project are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.0.0/); this project is
pre-1.0, so APIs may still shift between minor versions.

## [Unreleased]

- **Fix:** `Client#get` never retried anything — a transient Meta 429/5xx (or
  the platform's own throttling codes 4/17/32/613, which arrive as a bare
  HTTP 400) surfaced straight to the caller as a one-shot failure instead of
  being retried with backoff, same as every other adapter's `Client`. Now
  includes `Support::Retry` and wraps `#get` in `with_retry`.
- **Fix:** a code-190 `OAuthException` (expired/invalid access token) was
  indistinguishable from any other `ApiError` and, worse, was eligible for
  the retry loop above — retrying with the same dead token forever instead
  of failing fast. Now raised as its own `TokenExpiredError`, never retried,
  with a message pointing at re-minting the token via Business Login consent
  and `AccessTokenFetcher`.
- **Fix:** `ApiError` only exposed the HTTP status and raw body — reading
  Meta's own `error.code`/`error_subcode`/`fbtrace_id` (what Meta support
  asks for when escalating a request) meant reaching into `#body` by hand.
  Now exposed as `#code`/`#error_subcode`/`#fbtrace_id`.
- **Fix:** `Adapter#search_catalog` only ever fetched Meta's first page of
  results — a `limit` bigger than one page's worth silently returned fewer
  products than asked for. Now follows `paging.next` until `limit` is
  reached or the API runs out of pages, capped at `MAX_PAGES` requests.
- **Fix:** `AccessTokenFetcher#fetch` let a non-JSON response body (a 5xx
  from an edge/proxy, a truncated connection) raise an unrescued
  `JSON::ParserError` with no indication of what actually failed. Now raises
  a `Portage::Ucp::Instagram::Error` naming the HTTP status and raw body.
- **Fix:** `Mapper.money`/`.price`/`.order`/`.order_line_item` raised
  (`ArgumentError` from `BigDecimal`, `TypeError`/`NoMethodError` from a
  nested `.dig`/arithmetic on `nil`) on a malformed price string, an
  unexpected non-Hash `order_status`/`estimated_payment_details`/`items`, or
  a line item missing `quantity`/`price_per_unit` — any single malformed
  product or order could take down an entire catalog search or order fetch.
  All now degrade to a zero amount/empty collection instead.

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

- Initial pre-release. Instagram/Facebook Shops adapter against Meta's Graph
  API Commerce Catalog — catalog real, checkout redirect-link only, order
  lookup limited to "checkout on Instagram/Facebook" merchants.
