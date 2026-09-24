# Changelog

All notable changes to this project are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.0.0/); this project is
pre-1.0, so APIs may still shift between minor versions.

## [Unreleased]

- Fixes a `NoMethodError` at launch: `exe/portage-ucp-woocommerce` handed
  the server `Server.build(adapter:).start`, but `Server.build` returns a
  plain `MCP::Server` (mcp gem 0.25.0), which has no `#start` — only
  `MCP::Server::Transports::StdioTransport#open` reads stdio frames. The exe
  now calls that directly, matching `portage-ucp-etsy`'s exe. Adds
  `spec/portage/ucp/woocommerce/exe_spec.rb`, which runs the exe as a real
  subprocess and pipes it a JSON-RPC `initialize` + `tools/list` handshake
  to prove it actually starts and answers requests.

## [0.2.1] - 2026-09-23

- `Mapper.checkout_links`'s `resume-checkout` link now carries the cart
  token as a `?session=` query parameter, e.g.
  `<site_url>/checkout/?session=<cart_token>`. Without it, 0.2.0's link
  landed the shopper on a real checkout page with an *empty* cart: the
  CLI's cart lives in the Store API's token-based session (the `Cart-Token`
  header), while `/checkout/` reads the classic cookie-based session —
  two different rows in `wp_woocommerce_sessions` unless bridged.
  WooCommerce core already ships that bridge —
  `WC_Session_Handler#init_session_from_request` accepts the same Cart-
  Token JWT as `?session=` and clones the guest session's data into a
  fresh cookie session before the page renders — so this is a one-line
  fix, not new infrastructure. Confirmed live against the local Docker
  WooCommerce install (`docs/plans/woocommerce-local-validation.md`'s
  stack): `--auto-open`'s hand-off now opens a browser straight onto a
  checkout page with the cart's actual contents, not an empty one.
- `Resolver`'s WooCommerce `billing_address` is hardened: malformed
  `WOOCOMMERCE_BILLING_ADDRESS` JSON now raises a clear `ArgumentError`
  (previously a raw, uncaught `JSON::ParserError` out of `portage buy`),
  and when the env var is unset it falls back to the same `PORTAGE_SHIP_*`
  env `portage buy` reads for shipping, mapped to the Store API's billing
  field names, instead of leaving `billing_address` unset.

## [0.2.0] - 2026-09-22

- `Mapper.checkout` builds a `resume-checkout` link at `<site_url>/checkout/`
  for any non-completed checkout, instead of always emitting `links: []`.
  Without it, `Buy#checkout_url_of` returned `nil` and `Buy#hand_off` bailed
  out before it ran — confirmed live: the `no_payment_token` dead end
  reported `checkout_url: null` and `handoff: null`. `/checkout/` is
  WooCommerce's default slug, not guaranteed; a store that's renamed its
  checkout page gets a dead link. **Breaking for anyone calling `Mapper`
  directly**: `Mapper.checkout` now takes a required `site_url:` keyword.
- `Adapter.new` takes a `billing_address:` keyword (a Store API-shaped
  hash), supplied at construction from `WOOCOMMERCE_BILLING_ADDRESS` (JSON)
  by the `exe/portage-ucp-woocommerce` script. The Store API's `/checkout`
  endpoint 400s without one ("Missing parameter(s): billing_address"),
  confirmed live right after `payment_method` was wired through. UCP's
  `Adapter#complete_checkout` interface has no buyer-address parameter, and
  threading one through every adapter gem is a bigger change than this gem
  alone should make — same one-fixed-value-per-process stopgap as
  `payment_method`, and wrong the moment something needs a different
  address per checkout.

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

- Initial pre-release. WooCommerce adapter against the Admin REST API v3
  (catalog, order) and Store API v1 (cart, checkout).
