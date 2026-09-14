# Changelog

All notable changes to this project are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.0.0/); this project is
pre-1.0, so APIs may still shift between minor versions.

## [Unreleased]

- `Session` gains `#create_payment_enrollment(idempotency_key: nil)` /
  `#get_payment_enrollment(enrollment_id:)`, covering the new
  `app.portage-ucp.payment_enrollment` capability (docs/plans/agentic-payments.md
  Phase 1). `create_payment_enrollment` is added to `MUTATING_ACTIONS`, so a
  caller that omits `idempotency_key:` still gets one generated.

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
