# Changelog

All notable changes to this project are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.0.0/); this project is
pre-1.0, so APIs may still shift between minor versions.

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
