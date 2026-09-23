# Changelog

All notable changes to this project are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.0.0/); this project is
pre-1.0, so APIs may still shift between minor versions.

## [Unreleased]

- Fix: the loopback and stdio transports dropped `cart_id` from every call,
  so `get_cart`, `update_cart` and `cancel_cart` always failed with
  "Missing required arguments: cart_id". `cart_id` is a real-UCP wire
  argument only on `create_checkout` (the cart-to-checkout conversion), and
  now only that call drops it. The shared rule is
  `Transports::LocalArguments`.
- The UCP wire reshaping in `Transports::Http` moved to
  `Transports::UcpWireShape`, so other transports can build the same body.
  `portage-ucp-webmcp` uses it for UCP-shaped page tools. There is no
  behavior change for `Http`.

## [0.6.1] - 2026-09-22

- `ServerError` carries the parsed error document on `#payload` when the
  server's text content is JSON, with `#summary`, `#continue_url` and
  `#server_messages` readers over it. A real UCP server answers an
  out-of-stock `create_cart` with its whole `ucp` envelope — every
  capability, every payment handler — wrapped around a two-word
  `messages[].content` of "Sold out", so `#message` alone is several
  kilobytes of JSON and unusable by anything that has to show it to a
  person. `#message` is unchanged; the readers are additive, and return
  nil/`[]` for a refusal whose text isn't JSON.

## [0.6.0] - 2026-09-22

- `Transports::Http` now builds `checkout.payment.instruments[]` for
  `complete_checkout` against the card handler (`dev.shopify.card`) instead
  of unconditionally raising `UnsupportedWireShapeError`. Top level carries
  `id`/`checkout`; the instrument carries `id`/`handler_id`/`type`/
  `credential: { token:, type: }`, per the schema pulled live from
  `tools/list` 2026-09-22. `credential.type` (`dev.shopify.card_token`)
  follows the payment-handler-guide's reverse-DNS-plus-`_token` convention
  but is **not confirmed against a live response** — `complete_checkout` has
  never actually been called (no grant to test against; see
  `docs/ucp-tool-gating-investigation.md`). A `handler_id:` other than the
  card handler still raises `UnsupportedWireShapeError`, now naming the
  handler.
- `Session#complete_checkout` takes optional `handler_id:`/`credential_type:`
  to override the above; both are dropped by `Transports::{Loopback,Stdio}`
  same as `context:`/`cart_id:`, since neither means anything to an Adapter
  method signature.
- New `Client::PaymentPermissionError`, distinct from `ServerError` (a
  malformed/declined request) and `UnsupportedWireShapeError` (a handler
  this client can't build a request for). `Transports::Http` raises it when
  a `complete_checkout` refusal looks permission-shaped — going by the
  *pattern* of Shopify's other confirmed permission error
  (`get_order`'s `"You are forbidden to make tools/call requests"`) and the
  community-thread description of what's gated on `complete_checkout`
  (checkout-completion permission on the token, the merchant's channel
  enabled). This pattern match is also unconfirmed live.

## [0.5.0] - 2026-09-22

- `Session#search_catalog`/`#get_product`/`#lookup_catalog`/`#create_cart`/
  `#update_cart`/`#create_checkout`/`#update_checkout` take a `context:` — the
  UCP `context` object (`address_country`, `address_region`, `postal_code`,
  `currency`, `language`) — and `Transports::Http` nests it under the
  capability key. This reads as optional and isn't: a store resolves which
  market, and so which publication and inventory, a call is scoped to from it.
  A cart built without one comes back with `line_items: []`, zeroed totals and
  a `merchandise_out_of_stock` warning naming a product the same store's
  `search_catalog` returned as `available` seconds earlier — confirmed live
  2026-09-22. It failed open, with a plausible wrong answer instead of an
  error.
- `Session#create_checkout` takes a `cart_id:`, converting an existing cart
  into a checkout. `line_items:` stays required: `checkout.cart_id`'s own
  schema says a cart id alone is enough, and the live server rejects that with
  `missing required properties: line_items`, so `Transports::Http` sends both.
- `Transports::Loopback` and `Transports::Stdio` drop `context`/`cart_id`
  before dispatch. Both hand arguments to this gem's own server, which splats
  them into an Adapter method signature that has no such keywords.

## [0.4.0] - 2026-09-17

- Fixed `Transports::Http` sending every tool call in the flat, unwrapped
  shape this gem's own Dispatcher/adapters speak — real UCP servers
  (confirmed live against Shopify's 2026-08-25 rollout) reject it with a 422,
  since they expect arguments nested under a capability key
  (`catalog:`/`cart:`/`checkout:`) and a `meta.ucp-agent.profile` URL they
  fetch themselves to verify the caller's identity. `Http` now builds that
  real wire shape; `Loopback`/`Stdio` are unchanged, since the former talks
  to this gem's own Dispatcher (still the flat shape by design) and the
  latter has no confirmed real-world shape to fix. Callers must now pass
  `meta: { agent_profile: <url> }`, or `MissingAgentProfileError` explains
  what's missing instead of a bare 422.
- Added `MissingAgentProfileError` and `UnsupportedWireShapeError`.
  `complete_checkout` over HTTP raises the latter rather than guessing at
  the real payment-instrument shape (Apple Pay/Shop Pay/card-token variants
  each have distinct required credential fields) with no way to verify it
  against a real payment flow.
- Widens the `portage-ucp` dependency pin to `~> 0.8` so this gem installs
  alongside `portage-ucp` 0.8.0 (the `~> 0.7` pin published with 0.3.3 is
  pessimistic and excludes it).

## [0.3.3] - 2026-09-16

- No behavior change — 0.3.2 was built and pushed with `gem build` run from
  the workspace root instead of this gem's own directory, so `spec.files =
  Dir[...]` resolved against the wrong working directory and packaged an
  empty gem. 0.3.2 has been yanked; 0.3.3 repackages the exact same 0.3.2
  code correctly.

## [0.3.2] - 2026-09-16

- No behavior change — widens the `portage-ucp` dependency pin to `~> 0.7`
  so this gem can install alongside `portage-ucp` 0.7.0 (the pessimistic
  `~> 0.6` pin published with 0.3.1 excludes it).

## [0.3.1] - 2026-09-15

- No behavior change — widens the `portage-ucp` dependency pin to `~> 0.6`
  so this gem can install alongside `portage-ucp` 0.6.0 (the pessimistic
  `~> 0.5` pin published with 0.3.0 excludes it).

## [0.3.0] - 2026-09-14

- `Session` gains `#create_payment_enrollment(idempotency_key: nil)` /
  `#get_payment_enrollment(enrollment_id:)`, covering the new
  `app.portage-ucp.payment_enrollment` capability (docs/plans/agentic-payments.md
  Phase 1). `create_payment_enrollment` is added to `MUTATING_ACTIONS`, so a
  caller that omits `idempotency_key:` still gets one generated.
- Every transport (http, stdio, loopback) and `Session` grow an optional
  `meta:` kwarg, threaded through the same way `correlation_id` already
  reaches the server from `traceparent` — additive only, no caller passing
  `meta:` is required to change.
- Widened the `portage-ucp` dependency pin from `~> 0.4` to `~> 0.5` —
  `#create_payment_enrollment`/`#get_payment_enrollment` need the
  `app.portage-ucp.payment_enrollment` capability, only present from
  `portage-ucp` 0.5.0 on.

## [0.2.0] - 2026-08-21

- `Session#create_checkout`/`#update_checkout` gain an optional `fulfillment:`
  param, passed through only when given. Only exercised end-to-end over the
  loopback transport (an in-process `Adapter`, taking a real
  `Portage::Ucp::CheckoutFulfillment`); the stdio/HTTP wire shape for
  `fulfillment` has no real UCP server to verify it against yet, so it's not
  wired there.

## [0.1.0] - 2026-08-14

- Initial pre-release. Client-side SDK — loopback, stdio, and Streamable HTTP
  transports behind one `Session` interface.
