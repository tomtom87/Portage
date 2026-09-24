# Security hooks

## Security hooks — nothing is permissive by default

Read this before wiring a server up to anything real — every default here is deliberately locked down, not permissive-by-omission:

- **Authentication**: `Portage::Ucp::UnconfiguredAuthenticator` (the default) rejects every mutating call until you configure a real one. Implement `#call(server_context)` to return a truthy auth context, or raise `Portage::Ucp::AuthenticationError`.
- **Rate limiting**: `Portage::Ucp::NullRateLimiter` (the default) never limits. Implement `#check!(key, capability)` and raise `Portage::Ucp::RateLimitExceededError` to block a call.
- **PAN guard**: `Portage::Ucp::PaymentTokenGuard` rejects any `payment_token` that looks like a raw card number (digits-only, Luhn-valid, 12–19 chars) before it ever reaches your `Adapter` — `complete_checkout` must receive a tokenized credential.
- **Idempotency**: every mutating capability action takes an `idempotency_key:` — your `Adapter` is responsible for deduping retries (see `portage-ucp-shopify`'s in-process dedup table for one approach).
- **Observability**: `Portage::Ucp::Observability.log` emits structured JSON log events through a consumer-injected logger, redacting `payment_token`/`oauth_token`/`authorization` automatically.
- **Manifest signing**: `Portage::Ucp::Manifest` never generates or stores keys — pass a `signer` (anything responding to `#kid` and `#sign(canonical_json)`) to produce a signed manifest; omit it to serve unsigned.
- **Policy caps**: `Portage::Ucp::PolicyGuard`, wired into `Dispatcher` just before `complete_checkout` dispatch, enforces `Portage::Ucp::Policy`'s per-transaction/rolling caps, velocity limits, and merchant allowlist — plus per-token enrollment scopes (merchant/max-amount/currency) bound at enrollment time and checked by the same `token_ref` at charge time. Configured via `portage-cli`'s `portage policy show/set` and `portage payment enroll --scope-*`.
- **Confirmation**: `Portage::Ucp::Confirmer`, run right after `PolicyGuard.check!` passes and before `complete_checkout` dispatch. `Confirmer::Terminal` blocks on stdin and fails closed on anything but an explicit `"y"`; `Confirmer::AutoApprove` is for specs/conformance kits that need a real `confirm!` without blocking; `Confirmer::Webhook` is for out-of-band approval — POSTs to a configured URL and polls (or calls a caller-supplied `wait:` callback) until approve/deny/timeout, failing closed on timeout like `Terminal` but with a longer default (900s vs. 120s).
- **Payment enrollment**: `Portage::Ucp::PaymentEnrollmentGuard`, run via `Dispatcher#call`, validates every `create_payment_enrollment`/`get_payment_enrollment` response an adapter returns — `"pending"` must carry a `setup_url` and no `payment_token`, `"complete"` the reverse — raising `InvalidPaymentEnrollmentError` on a violation. An optional `mandate:` kwarg on the same two methods is shape-checked by `Portage::Ucp::Ap2::MandateGuard` (AP2 mandate shape, not cryptographic verification).
- **Inbound request signatures**: `Portage::Ucp::Security::Signature` / `Rack::SignatureVerification` verify RFC 9421 HTTP Message Signatures on inbound requests per UCP's signature spec — the same verify-before-parse posture as `Rack::WebhookEndpoint`, trusting `Manifest#signing_keys`' current+next JWK array.
- **Durable records**: `Portage::Ucp::Support::TransactionLog` reserves a transaction before `complete_checkout` dispatch and marks it settled/failed after, recording `PolicyGuard`/`Confirmer` outcomes on the same record. `Portage::Ucp::Support::OrderLedger` writes a durable snapshot alongside it once settlement succeeds — a failed snapshot write surfaces without flipping an already-settled charge to failed.

## WebMCP-specific hardening

`portage-ucp-webmcp`'s `CallEndpoint` (the Rack endpoint a page's `document.modelContext`
tool calls land on) adds two more limits on top of the above: a `max_body_bytes` cap
(1 MiB default, rejected with `413`) and a `call_timeout` (30s default) on the underlying
tool dispatch. Both are configurable per endpoint instance — see
[the WebMCP adapter page](adapters/webmcp.md) for the full README, including its
CSP/CSRF guidance.

## Shared HTTP client timeouts

Every bundled adapter's HTTP calls go through `Portage::Ucp::Support::HttpClient`, which
sets a default open timeout of 5s and read timeout of 30s, and retries a timeout once
through `Portage::Ucp::Support::Retry` rather than propagating it straight to the caller.
