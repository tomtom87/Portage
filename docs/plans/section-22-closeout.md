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
| 2 | `idempotency_provider` | ✅ done | race fixed §36; `Configuration#idempotency_provider` accessor added this session |
| 3 | §12 observability reconciliation | ✅ done | §23, correlation id + redaction; `event_sink` deliberately dropped |
| 4 | Inbound signature verification (AP2/UCP) | ✅ done | §31 (RFC 9421) + mandate crypto (PR #37, needs §34 already reconciled by §36) |
| 5 | Sandbox creds, 6 webmock-only adapters | ⛔ not started | **explicitly deferred by user, do later** |
| 6 | Storage abstraction + journal + console | ✅ done | §33 chose semantic-level Stores (TransactionLog/OrderLedger/Journal each own one) over a generic KV. Console shipped as `portage-console` (§37) — a read-only REPL, not the web/admin panel §16 also floated; that panel is still unbuilt and stays out of scope for item 6 (§16 already scoped it as a separate ask with its own auth requirement). |
| 7 | payment_method/saved-address/delete_shopper_data + scheduler | 🟡 partial | §32 shipped the first three. **Scheduler not started**, correctly gated behind item 2 |
| 8 | `portage compare` (find-it-elsewhere) | ✅ done | §27, `portage-cli/lib/portage/cli/compare.rb` |

## This session (2026-09-16, branch `console-repl-helpers`)

- Shipped item 6's remainder: `portage-console` (`portage-cli/exe/portage-console`,
  `Portage::Cli::Console`) — a read-only IRB REPL over `TransactionLog`,
  `OrderLedger`, and `PurchaseJournal`. Deliberately the REPL design-log §37
  argues for, not the auth-gated web panel §16 separately described.
- Added `#each_record`/`#all` to `TransactionLog`/`OrderLedger` (and their
  `Store` abstractions) in `portage-ucp` — the console is the second real
  consumer those classes' own doc comments said would trigger this; `#find`/
  `#completed_since` are untouched.
- `portage-cli` gained a runtime dependency on `portage-ucp-journal` (`~> 0.1`).
- Full suites green: `portage-ucp` 418 examples / 0 failures (119 files
  rubocop-clean); `portage-cli` 139 examples / 0 failures (34 files
  rubocop-clean).
- Design-log §37 records the decision (REPL over web panel, redaction posture,
  journal's "empty unless wired" caveat).

## Previous session (2026-09-16, branch `idempotency-provider-config`)

- Added `Configuration#idempotency_provider`, mirroring `rate_limiter`/
  `authenticator`: unset by default (unlike those two — deliberately, see
  code comment) so `Support::Idempotency#idempotency_store` keeps its
  per-instance `MemoryStore.new` fallback when nothing's configured, and
  only shares one store process-wide when a consumer opts in via
  `configure { |c| c.idempotency_provider = ... }`. A naive shared-by-default
  singleton would have broken test isolation (specs reuse literal keys
  like `"k1"` ~40x across files) — caught by running the full suite before
  settling on the opt-in shape.
  - `portage-ucp/lib/portage/ucp/configuration.rb`
  - `portage-ucp/lib/portage/ucp/support/idempotency.rb`
  - `portage-ucp/spec/support/idempotency_spec.rb`
- Full suite green: 407 examples / 0 failures, rubocop clean (116 files).

## Previous session (2026-09-16)

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

1. **Scheduler (item 7)** — item 2's plumbing (`Configuration#idempotency_provider`)
   is now solid; a scheduled purchase runs in a different process than the
   one that scheduled it. Needs: daemon/runner (none exists — repo is
   library + stdio exe only), price/stock drift policy at run time
   (max-price guard, `OutOfStockError` handling, skip/notify/proceed rule).
2. **Sandbox credentials, 6 adapters (item 5)** — deferred by user
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
