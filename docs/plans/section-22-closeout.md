# §22 close-out — running progress log

Scratch tracking doc for closing design-log §22's remaining handoff items.
Update this file at the end of each session instead of re-deriving status
from scratch. Source of truth for *why* is always `docs/design-log.md`
(§22 itself, plus §27/§31-36 which each closed or touched a piece of it) —
this file is just "where are we" so a new session can pick up without
re-reading the whole log.

Branch: `close-section-22` (off `origin/main`, which already has §35 +
AP2 crypto merged as PR #37).

## Item status

| # | Item | Status | Notes |
|---|------|--------|-------|
| 1 | `Checkout#links` | ✅ done | §22 handoff, shipped pre-existing |
| 2 | `idempotency_provider` | 🟡 partial | race fixed §36 (this session); `Configuration` accessor still missing |
| 3 | §12 observability reconciliation | ✅ done | §23, correlation id + redaction; `event_sink` deliberately dropped |
| 4 | Inbound signature verification (AP2/UCP) | ✅ done | §31 (RFC 9421) + mandate crypto (PR #37, needs §34 already reconciled by §36) |
| 5 | Sandbox creds, 6 webmock-only adapters | ⛔ not started | **explicitly deferred by user, do later** |
| 6 | Storage abstraction + journal | 🟡 partial | §33 chose semantic-level Stores (TransactionLog/OrderLedger/Journal each own one) over a generic KV — that's a closed decision, not a gap. Only the **console** is still unbuilt. |
| 7 | payment_method/saved-address/delete_shopper_data + scheduler | 🟡 partial | §32 shipped the first three. **Scheduler not started**, correctly gated behind item 2 |
| 8 | `portage compare` (find-it-elsewhere) | ✅ done | §27, `portage-cli/lib/portage/cli/compare.rb` |

## This session (2026-09-16)

- Fixed real cross-process race in `Support::Idempotency#dedup`: `fetch`
  then `store` were two separate `FileStore` lock acquisitions, so two
  `portage` processes could both observe `NOT_FOUND` and both run the
  mutation. Added `Store#fetch_or_store` (one lock, whole check-then-set)
  to both `MemoryStore` and `FileStore`, switched `dedup` to use it.
  Proved with a `Process.fork` spec — confirmed it fails against the old
  code before confirming it passes against the fix.
  - `portage-ucp/lib/portage/ucp/support/idempotency.rb`
  - `portage-ucp/lib/portage/ucp/support/idempotency/{memory_store,file_store}.rb`
  - `portage-ucp/spec/support/idempotency/file_store_spec.rb`
- Wrote design-log §36: reconciles §34's stale "shape-only, no crypto"
  AP2 claim against the mandate signature verification that shipped in
  PR #37, and documents the idempotency race fix above.
- Full suite green: 405 examples / 0 failures, rubocop clean.

## Next up (not started, in rough dependency order)

1. **`Configuration#idempotency_provider`** — the plumbing item 2 still
   owes: promote store selection onto `Configuration`, mirror the
   `rate_limiter`/`authenticator` pattern (`configure { |c| c.rate_limiter = ... }`),
   so a consumer doesn't have to reach into `idempotency_store=` on every
   adapter instance individually.
2. **Scheduler (item 7)** — blocked on (1) being solid: a scheduled
   purchase runs in a different process than the one that scheduled it.
   Needs: daemon/runner (none exists — repo is library + stdio exe only),
   price/stock drift policy at run time (max-price guard, `OutOfStockError`
   handling, skip/notify/proceed rule).
3. **Console (item 6's remainder)** — reads the storage layer §33 built,
   never the logs. Needs its own session auth (separate from
   `Authenticator`, which guards MCP calls not a web UI) and every
   rendered field routed through `Observability.redact`. Localhost-bound
   by default.
4. **Sandbox credentials, 6 adapters (item 5)** — deferred by user
   instruction, pick up later. BigCommerce/Etsy/Instagram/Magento/Wix/
   WooCommerce are webmock-only; `.env.example` has no real values for any
   of them. One at a time, run the §17 conformance kit against each real
   store — expect bugs of the same class Shopify's real store surfaced.

## Open questions / not yet decided

- Redis (or similar) `idempotency_provider` implementation: `Support::Idempotency`
  is documented as a two-method interface (`#fetch`/`#store`, now also
  `#fetch_or_store`) specifically so a consumer can bring their own —
  core still ships no Redis-backed store, by design (§9's "no storage
  assumption"). Confirm this stays a documented consumer responsibility
  rather than something core should ship before closing item 2 fully.
