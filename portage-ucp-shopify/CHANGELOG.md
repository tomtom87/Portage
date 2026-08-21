# Changelog

All notable changes to this project are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.0.0/); this project is
pre-1.0, so APIs may still shift between minor versions.

## [Unreleased]

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

## [0.1.0] - Unreleased

- Initial pre-release. Shopify adapter against the Admin (catalog, order) and
  Storefront (cart, checkout) GraphQL APIs.
