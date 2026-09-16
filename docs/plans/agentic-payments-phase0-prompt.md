# Prompt for next coding agent: Agentic Payments — Phase 0

Read `docs/plans/agentic-payments.md` in full first — it has the context, constraints, and later phases. This prompt covers Phase 0 only.

## Task

Implement Phase 0 ("Durable idempotency + transaction log") from the plan above, in the `portage-ucp` gem.

## Part A — durable idempotency store

`portage-ucp/lib/portage/ucp/support/idempotency.rb` currently dedupes via an in-process, mutex-protected in-memory table (`Support::Idempotency#dedup`), included as a mixin by every adapter (reference, Shopify, BigCommerce, Magento, WooCommerce, Wix, Etsy, Instagram). This is lost on process restart and not shared across processes — the real bug this phase fixes.

- Extract a store interface (something like `#fetch(key) / #store(key, value)`, exact shape is your call — keep it minimal) that `Idempotency#dedup` delegates to instead of a raw in-memory hash.
- Ship a default file-based implementation using `flock` for cross-process safety, since this gem's primary consumer today is a single-host CLI.
- Make the store injectable (constructor arg or similar) so a server deployment can swap in Redis/SQLite later — don't build those backends now, just make sure the seam exists and is easy to implement against.
- Update all adapters that include the mixin to work with the new interface (should be transparent if the mixin's public method signature doesn't change).
- Add/update specs for the idempotency mixin covering: same key twice returns the memoized result, different keys don't collide, and (for the file store) surviving a fresh process re-reading the file behaves correctly.

## Part B — transaction log

New file, `~/.portage/transactions.json` (or sharded per-shop if that's cleaner given the existing `~/.portage/history.json` pattern in `portage-cli/lib/portage/cli/history.rb` — match whichever convention fits best, your call).

Record shape per transaction:
```
{
  idempotency_key:, shop:, checkout_id:, status: "pending" | "complete" | "failed",
  policy_decision: nil,        # populated by a later phase, leave the field present but unused
  confirmation_outcome: nil,   # populated by a later phase, leave the field present but unused
  payment_token_ref:, amount:, currency:, created_at:, completed_at:
}
```

Hard requirements — these deliberately diverge from the existing `history.rb` / `probe_cache.rb` / `search_backends.rb` convention, and the divergence is intentional, not an oversight:

1. **`chmod 0600`** on every write. None of the existing `~/.portage/*` files do this — this is a new, explicit convention for anything payment-adjacent. Comment why in the code.
2. **Write failures must raise, not be swallowed.** The existing stores wrap writes in `rescue StandardError; nil`. Do NOT copy that pattern here — a silently failed write on this file means transaction/dedup state silently drifts, and a subsequent run could re-charge or misjudge spend state. Let it raise.
3. **Reserve-then-commit.** Write the record with `status: "pending"` *before* calling `complete_checkout` (or equivalent dispatch), then update it to `complete`/`failed` after the response comes back. A process crash mid-charge must leave a `pending` record behind, not nothing.

Wire this into wherever `complete_checkout` (or the equivalent mutating dispatch path) currently runs — likely `portage-ucp/lib/portage/ucp/dispatcher.rb` or the CLI's `buy.rb`, check both and use whichever is the actual call site closest to the gateway round-trip. `policy_decision` and `confirmation_outcome` fields exist in the schema now so Phase 2/3 don't need a schema migration later, but leave them `nil` — no policy engine or confirmation logic in this phase.

## Explicit non-goals for this task

- No `PolicyGuard`, no spend caps, no allowlist, no confirmation prompt — that's Phase 2/3.
- No keychain/payment-method storage, no `portage payment` subcommands — that's Phase 1.
- No changes to `buy.rb`'s `--payment-token` requirement or the `requires_escalation` flow.

## Before you start

- Confirm current behavior of `complete_checkout` and the idempotency mixin with a quick read of `adapter.rb`, `dispatcher.rb`, and the mixin itself — the plan doc's line references may have drifted since it was written.
- Check `CHANGELOG.md` at repo root for version-bump conventions before touching gemspec versions, if that turns out to be needed.
