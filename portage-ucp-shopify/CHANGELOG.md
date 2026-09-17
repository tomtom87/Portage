# Changelog

All notable changes to this project are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.0.0/); this project is
pre-1.0, so APIs may still shift between minor versions.

## [0.4.4] - 2026-09-17

- No behavior change — widens the `portage-ucp` dependency pin to `~> 0.8`
  so this gem can install alongside `portage-ucp` 0.8.0 (the `~> 0.7` pin
  published with 0.4.3 is pessimistic and excludes it). Also documents, at
  `Adapter#cart_lines`, that the conformance kit's `line_items[].product_id`
  means a `ProductVariant` GID here, not the parent `Product` GID — the
  caller resolves that, this adapter doesn't.

## [0.4.3] - 2026-09-16

- No behavior change — 0.4.2 was built and pushed with `gem build` run from
  the workspace root instead of this gem's own directory, so `spec.files =
  Dir[...]` resolved against the wrong working directory and packaged an
  empty gem. 0.4.2 has been yanked; 0.4.3 repackages the exact same 0.4.2
  code correctly.

## [0.4.2] - 2026-09-16

- Fix `GraphqlError` crashing with `NoMethodError` instead of surfacing the
  real message when Shopify's `errors` field is a bare string rather than
  the usual array of objects (confirmed live on an expired/invalid admin
  token).
- Add a live-store spec that searches the catalog, buys a random in-stock
  product through checkout creation, and retries past a line Storefront
  silently rejects (`quantity: 0`, empty `userErrors`) despite the Admin
  API reporting it available.
- Widens the `portage-ucp` dependency pin to `~> 0.7` so this gem can
  install alongside `portage-ucp` 0.7.0 (the pessimistic `~> 0.6` pin
  published with 0.4.1 excludes it).

## [0.4.1] - 2026-09-15

- No behavior change — widens the `portage-ucp` dependency pin to `~> 0.6`
  so this gem can install alongside `portage-ucp` 0.6.0 (the pessimistic
  `~> 0.5` pin published with 0.4.0 excludes it).

## [0.4.0] - 2026-09-14

- Added `Adapter#lookup_catalog(ids:)` — fetches several known product ids in
  one round trip via the Admin API's `nodes(ids:)` field, instead of one
  `get_product` call per id. Mirrors Shopify's real `search_catalog`/
  `lookup_catalog` split, and reuses `Mapper.product` against the same node
  shape `get_product`/`search_catalog` already use.
- Widened the `portage-ucp` dependency pin from `~> 0.4` to `~> 0.5` —
  `lookup_catalog` is only advertised by the base `Adapter` from
  `portage-ucp` 0.5.0 on.

## [0.3.1] - 2026-08-28

- Widened the `portage-ucp` dependency pin from `~> 0.3` to `~> 0.4` —
  `portage-ucp` bumped to 0.4.0 (reorder capability, correlation ids,
  PII redaction), and this gem is published, so its old pin would refuse
  the new core version on install. No code change in this gem itself.

## [0.3.0] - 2026-08-27

- `metadata_field` config DSL (`Configuration`) — lets a merchant map their
  own Shopify metafields onto UCP catalog attributes without a code change,
  instead of every merchant-specific field needing a fork of `mapper.rb`.
- Four catalog/cart GraphQL shape fixes against the real Admin/Storefront
  API, none catchable by `adapter_spec.rb`'s hand-rolled webmock stubs since
  those fabricate response shapes by hand:
  - `ProductVariant#price`/`#compareAtPrice` are the bare `Money` scalar (a
    decimal string), not a `MoneyV2` object — the live Admin API 2026-04
    schema rejects `{ amount currencyCode }` sub-selections on them.
  - `ProductCompareAtPriceRange`'s fields are `minVariantCompareAtPrice`/
    `maxVariantCompareAtPrice`, not `minVariantPrice`/`maxVariantPrice`
    (those belong to `ProductPriceRangeV2` and were copy-pasted onto the
    compare-at query and mapper).
  - Cart `deliveryGroups` is a connection (`.nodes`), not a bare array.
  - Cart `totalTaxAmount` is nullable — a fresh cart genuinely has no tax
    amount yet rather than a zero one, until Shopify has enough context
    (shipping address, tax-registered market) to compute it.
- Bounded retry with backoff and normalized conflict/throttle errors on
  requests to Shopify, via the core gem's new `Support::Retry`.
- Per-cart/checkout mutations against Shopify are now serialized per session
  (core gem's new `Support::SessionLock`), so two concurrent requests against
  the same cart can't race each other.
- `existing_variant_id` support in the adapter conformance kit — Shopify
  needs a Product GID for catalog lookups and a separate ProductVariant GID
  for cart line items, which `existing_product_id` alone can't express.
- Adapter now runs the core gem's conformance kit against a real `Adapter`
  through a real `Dispatcher` (`spec/portage/ucp/shopify/conformance_spec.rb`).

## [0.2.0] - 2026-08-21

- `CartInput.discountCodes` on create, `cartDiscountCodesUpdate` on update —
  backs the core gem's new `dev.ucp.shopping.discount` extension, same
  full-replacement posture `update_cart`'s line-item handling already uses.
  `CART_FIELDS` grows `discountCodes` and `discountAllocations`; `#discounts`
  treats the former as every code Shopify has on record and the latter as the
  applied list. `AppliedDiscount#allocations` is left unpopulated —
  `discountAllocations` doesn't resolve to a line-item index without a second
  per-line query this pass didn't add. Only Shopify implements this so far.
- `dev.ucp.shopping.fulfillment` mapped onto Cart `deliveryGroups`: an address
  via `cartDeliveryAddressesAdd`, a rate selection via
  `cartSelectedDeliveryOptionsUpdate`. Storefront has no "fulfillment method"
  above `deliveryGroups`, so the adapter synthesizes one `FulfillmentMethod`
  per checkout wrapping all of a cart's `deliveryGroups` underneath it — see
  design-log. The two mutations' input shapes
  (`CartSelectableAddressInput`, `CartSelectedDeliveryOptionInput`) are this
  pass's best-effort mapping, same unconfirmed-against-a-real-store caveat
  `cartPaymentUpdate` already carries; the nullability mismatch on
  `cartDiscountCodesUpdate`'s clear-codes path was caught and fixed against a
  dev store, this one is still pending.
- `#complete_checkout` now raises `Portage::Ucp::OutOfStockError` (design-log
  §16 "Stock/availability going stale") when a cart line is no longer
  available for sale, instead of the generic `Portage::Ucp::Shopify::Error`
  every other submission failure raises. Checked against a live dev store:
  `cartSubmitForCompletion`'s `SubmitFailed` result doesn't give a sold-out
  line its own error code — Shopify raises the same
  `NO_DELIVERY_GROUP_SELECTED` it uses for an ordinary in-progress checkout
  that hasn't picked a delivery option yet, so that mutation's errors can't
  tell stale stock apart from an ordinary incomplete checkout. Detection
  instead reads each line's `merchandise.availableForSale` off the cart
  itself, before a payment is attempted.
- `#cancel_order` (`orderCancel`), `#refund_order` (`suggestedRefund` +
  `refundCreate`), `#request_return` (`returnCreate`) — implements the core
  gem's new `dev.ucp.shopping.order` cancel/return/refund extension. Each
  re-fetches the order afterwards rather than trusting the mutation's own
  payload, same posture as `#cancel_checkout`; the resulting
  cancellation/refund/return state is read off `GET_ORDER`'s
  `cancelledAt`/`refunds`/`returns` fields into `Order#adjustments`.

## [0.1.0] - 2026-08-14

- Initial pre-release. Shopify adapter against the Admin (catalog, order) and
  Storefront (cart, checkout) GraphQL APIs.
