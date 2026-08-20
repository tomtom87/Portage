# Changelog

All notable changes to this project are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.0.0/); this project is
pre-1.0, so APIs may still shift between minor versions.

## [Unreleased]

- `#complete_checkout` now raises `Portage::Ucp::OutOfStockError` (design-log
  §16 "Stock/availability going stale") when `cartSubmitForCompletion`'s
  `SubmitFailed` result carries an error code that looks stock-related,
  instead of the generic `Portage::Ucp::Shopify::Error` every other
  submission failure raises. The exact `SubmissionErrorCode` values Shopify
  uses for a sold-out line item aren't pinned down without a live dev-store
  reproduction, so detection is a code-substring match rather than an exact
  enum comparison — same caveat as this method's payment sub-shape.
- `#cancel_order` (`orderCancel`), `#refund_order` (`suggestedRefund` +
  `refundCreate`), `#request_return` (`returnCreate`) — implements the core
  gem's new `dev.ucp.shopping.order` cancel/return/refund extension. Each
  re-fetches the order afterwards rather than trusting the mutation's own
  payload, same posture as `#cancel_checkout`; the resulting
  cancellation/refund/return state is read off `GET_ORDER`'s
  `cancelledAt`/`refunds`/`returns` fields into `Order#adjustments`.

## [0.1.0] - Unreleased

- Initial pre-release. Shopify adapter against the Admin (catalog, order) and
  Storefront (cart, checkout) GraphQL APIs.
