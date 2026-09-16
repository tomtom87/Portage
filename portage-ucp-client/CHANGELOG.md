# Changelog

All notable changes to this project are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.0.0/); this project is
pre-1.0, so APIs may still shift between minor versions.

## [Unreleased]

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
