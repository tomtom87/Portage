# Security

This document pulls the trust-boundary reasoning that matters for anyone integrating
or auditing Portage out of [`docs/design-log.md`](https://github.com/tomtom87/Portage/blob/main/docs/design-log.md) (154KB of
decision history) into one place. It doesn't replace the design log — where a topic
below says "see §N", that's where the full reasoning and alternatives-considered live.

If you've found a vulnerability, please report it privately rather than opening a
public issue.

## Idempotency store: `Marshal` trusts its own process, not its writer

`Portage::Ucp::Support::Idempotency::FileStore`
(`portage-ucp/lib/portage/ucp/support/idempotency/file_store.rb`) persists dedup
entries with `Marshal`, not JSON. That's safe **only** because the file is written and
read by the same trusted local process/user — file mode `0600`, no network exposure,
the same trust boundary the CLI process already sits inside (design-log: *"local
policy guards agent mistakes, not a compromised agent"*).

**The threat this creates if that assumption breaks:** `Marshal.load` on a file an
untrusted process can write to is a deserialization RCE primitive — arbitrary object
construction, not just arbitrary data. There's no cryptographic integrity check on the
file; the only controls are the file permission and a lock file. **Never point
`FileStore` at a path another user, process, or container can write to.**

Two related, deliberate non-goals rather than bugs: a truncated write or a
renamed/removed class (Marshal replays the dumped class name on load) both "poison
this file forever" — handled by treating any read error as an empty store rather than
attempting to validate or repair the deserialized shape. And `FileStore` is opt-in: the
injected default is `MemoryStore`, so this trust widening only applies if a consumer
deliberately constructs `FileStore` (see also `Configuration#idempotency_provider`'s
own warning against using it as a process-wide store in a long-lived server —
`portage-ucp/lib/portage/ucp/configuration.rb`).

## RFC 9421 HTTP Message Signatures: verifying the calling platform, not the payload

`Portage::Ucp::Security::Signature` and `Rack::SignatureVerification`
(`portage-ucp/lib/portage/ucp/security/signature.rb`,
`portage-ucp/lib/portage/ucp/rack/signature_verification.rb`) verify inbound requests
against **the calling platform's own signing key** — a different trust root from
mandate signing below (that's the *shopper's agent's* key; this is the *platform
sending you the request's* key).

What's checked: ECDSA over the exact method/authority/path/(query)/covered headers
(P-256 required, P-384 optional, raw `r‖s` encoding), a content-digest match when a
body is present, and freshness (`created` within `max_age`, default 300s). Verification
happens on the **raw, unparsed body** before it's handed to the wrapped app — "an
unverified body is untrusted input" — the body is only rewound for the app after
`verify!` succeeds. A bad or missing signature raises a typed `SignatureError`
subclass rather than returning a falsy value, so a caller can't accidentally treat a
failed verification as a pass; the Rack middleware turns that into a `401
invalid_signature` with the specific reason logged.

**Replay is bounded, not eliminated.** RFC 9421 leaves freshness enforcement to the
verifier — this gem's `max_age` window is that enforcement. `required_components`
defaults to `@method @authority @path idempotency-key` specifically so a captured
signed request can't be replayed against a *different* mutation (the idempotency key is
part of what's signed) — but within the freshness window and against the *same*
mutation, a captured valid signature is still valid. Key rotation is current+next JWK
entries in `trusted_keys` (same shape as `Manifest#signing_keys`, different data — do
not conflate the two key sets).

## AP2 mandate signing: cryptographic when a trust anchor exists, shape-only otherwise

`Portage::Ucp::Ap2::MandateSignature` / `MandateGuard`
(`portage-ucp/lib/portage/ucp/ap2/mandate_signature.rb`,
`portage-ucp/lib/portage/ucp/ap2/mandate_guard.rb`) validate a payment mandate in two
layers that **do not run with the same strength by default**:

- **Shape, always**: required fields present (`amount currency merchant expires_at
  signature`) and not expired. This runs unconditionally.
- **Cryptographic, only if `mandate_trusted_keys` is configured**: ECDSA over the
  mandate's signing payload against the issuer's key set (the shopper's agent, or the
  agent platform vouching for it) — the same P-256/P-384 JWK conventions as the RFC
  9421 path above, but a *separate* trust root again.

**Fail-open by default.** With no `mandate_trusted_keys` and
`require_mandate_signature: false` (the default), a mandate that passes shape
validation is accepted with no cryptographic proof behind it — this is not a silent
downgrade, it's the posture the guard has always had, reflecting that "no key
infrastructure or trust anchor exists in this repo to verify a signature against" out
of the box. Setting `require_mandate_signature: true` makes a missing
`mandate_trusted_keys` raise `InvalidMandateError` instead — the explicit fail-closed
opt-in (design-log §33). **A real PSP integration relying on mandate authorization
must supply `mandate_trusted_keys` and flip `require_mandate_signature` on** — the
unconfigured default exists to keep an integration-in-progress working, not to be
production posture.

## Payment tokens: a format tripwire, not proof of tokenization

`Portage::Ucp::PaymentTokenGuard` (`portage-ucp/lib/portage/ucp/payment_token_guard.rb`)
enforces the boundary stated throughout this codebase: **`complete_checkout`'s
`payment_token` must be a single-use, tokenized credential from a UCP payment handler
or AP2 exchange — never a raw PAN.** It rejects any string that is digits-only,
12–19 characters, and Luhn-valid.

This is a heuristic, explicitly: *"This can't prove a string is an opaque token, but it
can catch the clearest misintegration."* A real payment token that happens to be an
all-digit, Luhn-valid string of the right length would pass this check uncaught — the
guard exists to catch an adapter or client accidentally passing a raw card number
through, not to fraud-detect every possible misuse. Treat a passing check as "not
obviously wrong," not as "confirmed safe."

`PaymentEnrollmentGuard` (`portage-ucp/lib/portage/ucp/payment_enrollment_guard.rb`) is
the narrower, analogous check on `create_payment_enrollment`/`get_payment_enrollment`
responses (e.g. `status: "complete"` must carry a `payment_token`, `"pending"` must
not) — same posture: catch clear misintegration, don't attempt to prove full validity.

## Webhook HMAC: verified before parsed, not protected against replay

`Portage::Ucp::Rack::WebhookEndpoint` (`portage-ucp/lib/portage/ucp/rack/webhook_endpoint.rb`)
verifies an HMAC-SHA256 signature against the **raw request body** before any JSON
parsing happens — never trust a payload before it's authenticated — using
`Rack::Utils.secure_compare` (constant-time) rather than a manual string comparison.

**This path has no replay protection** — no timestamp or nonce check anywhere in this
file, unlike the RFC 9421 path above, which does enforce a freshness window. A captured,
validly-signed webhook payload can be replayed indefinitely. If replay matters for your
integration (e.g. a webhook that triggers a side effect you can't safely repeat), add
your own idempotency check keyed on something in the payload (an order/event id) before
acting on it — this gem's dedup primitives
(`Portage::Ucp::Support::Idempotency`) aren't wired into this endpoint automatically.

## Observability redaction: unconditional on the log path, reused on the trace path

`Portage::Ucp::Observability` (`portage-ucp/lib/portage/ucp/observability.rb`) redacts
`payment_token`, `oauth_token`, `authorization`, and the PII fields that actually appear
on `Identity`/`PostalAddress` (email, name, phone, address components) plus
`psp_reference`, at any nesting depth, before anything is logged. This redaction is
**unconditional** on the JSON-to-`Logger` path. The opt-in OTel span emitter (only
active if a consumer sets `Configuration#tracer`) reuses the same already-redacted
field set rather than a separate, potentially-unredacted path — there is no way to get
raw payment/PII data into either sink through this module.

## Summary: what's checked vs. assumed, at a glance

| Boundary | Verified | Not verified / explicit non-goal |
|---|---|---|
| Idempotency `FileStore` | File mode `0600`, lock-based coordination | No integrity check on deserialized content — never share the file with an untrusted writer |
| RFC 9421 inbound signatures | Signature, freshness (`max_age`), content digest | Replay within the freshness window against the *same* mutation |
| AP2 mandate signature | Shape always; crypto only if `mandate_trusted_keys` set | Fails open (shape-only) unless `require_mandate_signature: true` |
| `payment_token` | Not a raw-PAN-shaped string (Luhn heuristic) | Not proof the string is actually an opaque token |
| Webhook HMAC | Signature (constant-time compare), verified pre-parse | Replay — no timestamp/nonce |
| Observability | Payment/PII fields redacted before logging or tracing | N/A — no known gap |
