# Storage Abstraction + Buyer-Side Purchase Journal

**Status:** planned, not started
**Driver:** design-log §22, "Persistence is the common dependency." `TransactionLog`/`OrderLedger` (0.5.0) each hand-roll their own file/flock/JSON convention. Console and scheduler work (§22, both unbuilt) will need the same shape a third and fourth time unless one injectable store gets decided now, in the `rate_limiter`/`authenticator` mold.

## Context

`Support::TransactionLog` and `Support::OrderLedger` ([transaction_log.rb](../../portage-ucp/lib/portage/ucp/support/transaction_log.rb), [order_ledger.rb](../../portage-ucp/lib/portage/ucp/support/order_ledger.rb)) both live in core, both hardcode a `~/.portage/*.json` path, and both duplicate the same `with_lock`/`read`/`persist` trio verbatim. Neither is swappable — a consumer who wants Redis, a real DB, or an in-memory store for tests has no seam, only the `path:`/`clock:` constructor args each class happens to expose.

Separately, nothing today records the buyer's own purchase history in one durable, consumer-agnostic place. `TransactionLog` is payment-dispatch bookkeeping (reserve/commit, spend caps) and `OrderLedger` is a settled-`Order` snapshot; neither is shaped as an append-only journal of "what did I buy, where, for how much," and both are core-gem concerns wired straight into `Dispatcher`. §22 also flags that persistence is about to be needed a third time (an admin/console panel, unbuilt, blocked on this) and a fourth (a scheduler, unbuilt, needs cross-process idempotency storage too) — building the journal without settling the shared abstraction first repeats `TransactionLog`/`OrderLedger`'s duplication a third time.

**Why this is a new gem, not more of core.** §2's architecture keeps `portage-ucp` a dependency-light, adapter-agnostic library. `TransactionLog`/`OrderLedger` got away with living in core because they add zero runtime dependencies (stdlib `json`/`fileutils` only) and are payment-safety-critical enough to want zero optional-require indirection. The journal is neither: it's an optional, buyer-side convenience a consumer opts into, and §22 explicitly says a console or scheduler built on the same storage seam "want their own gems." Bundling the store abstraction with the journal in one new gem, rather than core, keeps that precedent intact and gives a future console/scheduler gem something to depend on without pulling in core's payment-path internals.

## Non-negotiable constraints

- **Core gains no new runtime dependency and no required gem.** `Dispatcher` gets one new optional constructor argument (`journal: nil`) and one `@journal&.record(...)` call at the existing `complete_checkout` settle point — nil-checked, never `require`d from core. A consumer wires the journal in from their own app, the same way `authenticator`/`rate_limiter` are opt-in via `Configuration`.
- **The store abstraction is generic, not journal-shaped.** `Portage::Ucp::Journal::Store` (the new gem's core class) exposes only what an append-only consumer needs today — `#append(record)` / `#each_record`. Resist adding `#get`/`#put`/keyed lookups speculatively for a console or scheduler that doesn't exist yet; extend the interface when a second, real consumer needs more than append-and-replay, not before.
- **`FileStore` is the shipped default, not a null object.** Unlike `NullRateLimiter`/`UnconfiguredAuthenticator`, an unconfigured journal that silently drops every write defeats the point of a purchase record. The gem ships one real, durable implementation (JSON Lines, `flock`-guarded, `0600`, genuinely append-only — no read-modify-rewrite-whole-file the way `TransactionLog`/`OrderLedger` do) as the default a consumer gets for free.
- **Reuse the existing wire vocabulary — from `Checkout`, not `Checkout#order`.** `Checkout#order` is only ever an `order_confirmation` stub (`id`/`permalink_url`/`label`, [value_objects.rb:395](../../portage-ucp/lib/portage/ucp/value_objects.rb#L395)) — it has no `line_items` of its own. The journal entry's `product_id`/`quantity`/`amount`/`currency` come from the settled `Checkout#line_items` (`LineItem`/`Item`, [value_objects.rb:194](../../portage-ucp/lib/portage/ucp/value_objects.rb#L194)) — the same `result` `Dispatcher#settled_amount`/`#settled_currency` already read — and `order_id` from `Checkout#order&.id`. No new schema, no re-fetch.
- **Amounts are minor units + currency, never a float** — same rule as everywhere else in this codebase (`Support::Amounts`/`Total#amount`).
- **`source` distinguishes `native_ucp` from `adapter:<platform>`**, per §22's own wording — the journal is meant to answer "where did this purchase happen," which `shop` (a bare string today) doesn't capture on its own.
- **Write failures raise, same posture as `TransactionLog`/`OrderLedger`.** A silently lost journal entry is an unnoticed hole in the buyer's own record; don't add a `rescue StandardError; nil`.
- **Journal write must not fail a settled charge**, same ordering constraint `order-ledger.md` already established for `OrderLedger`: write after `@transaction_log.complete`, and let a write failure surface only once the transaction record is already durably `complete`.

## Phases

### Phase 1 — `portage-ucp-journal` gem: store abstraction + `FileStore`

- New gem, depends on nothing but stdlib at runtime (no `portage-ucp` runtime dependency either — the abstraction doesn't need any core type to exist).
- `Portage::Ucp::Journal::Store` — abstract, `#append(record)`/`#each_record` both raise `NotImplementedError`, doc comment states the "no default no-op" reasoning above.
- `Portage::Ucp::Journal::FileStore` — JSON-Lines file at `~/.portage/journal.jsonl` by default (`path:` injectable, same as `TransactionLog`), one `File.open(..., File::WRONLY | File::CREAT | File::APPEND, 0o600)` + `flock(LOCK_EX)` + single-line `JSON.generate` + newline per `#append` — never rewrites the whole file, unlike `TransactionLog`/`OrderLedger`. `#each_record` opens for read, `flock(LOCK_SH)`, yields one parsed hash per line, skipping (not raising on) a torn trailing line from a crash mid-append.
- Specs: append then replay in a fresh instance returns what was written, in order; a torn last line doesn't lose earlier entries; concurrent appends from two instances don't interleave a single line (flock).

### Phase 2 — `PurchaseJournal` + `Dispatcher` hook

- `Portage::Ucp::Journal::PurchaseJournal` wraps a `Store` (`FileStore.new` by default) and exposes `#record_checkout(shop:, source:, checkout:, idempotency_key:)` — one journal entry per `checkout.line_items` entry (`product_id` from `item.id`, `quantity` bare, `amount`/`currency` from the line's own `totals` `type: "total"` entry + `checkout.currency`), each entry also carrying `order_id` (`checkout.order&.id`), the shared `idempotency_key`, and `recorded_at`. Plus `#each_record`/`#all` (thin passthrough to the store) — no filtering/query surface yet; that's console territory, out of scope here.
- `portage-ucp` core: `Dispatcher.new` gains `journal: nil` (nil-default, no `require "portage/ucp/journal"` anywhere in core). In `call_and_log_transaction`, after the existing `@order_ledger.record(...) if result.order` line, add a guarded `@journal.record_checkout(shop: @shop, source: journal_source(@adapter), checkout: result, idempotency_key: idempotency_key) if @journal && result.order`. `journal_source` is `"native_ucp"` vs `"adapter:#{platform}"`, read off `@adapter.class.name`'s second-to-last namespace segment (`Portage::Ucp::Shopify::Adapter` → `"adapter:shopify"`), with the in-repo `ReferenceAdapter` (and any anonymously-named adapter) reporting `"native_ucp"`. This is a heuristic, not a real platform-identity concept `Dispatcher` has any other source for — revisit if a real adapter's namespace ever doesn't line up with its platform name.
- A consumer opts in by constructing `Dispatcher.new(adapter: ..., journal: Portage::Ucp::Journal::PurchaseJournal.new)` after `require "portage/ucp/journal"` in their own app — same shape as wiring in a real `rate_limiter`.
- Specs: a completed checkout with an order present writes one entry per line item, joinable by `idempotency_key`; a nil `journal:` (the default) is a no-op, matching today's behavior exactly; a journal write failure raises only after the transaction record is already `complete` (mirrors `order-ledger.md`'s Phase 1 spec #3).

## Open decisions

1. Exact `source` string for non-Shopify/adapter-agnostic dispatch (e.g. the `ReferenceAdapter`, or a `Dispatcher` driven directly against a hand-rolled `Adapter` with no platform identity at all). Decide once Phase 2 is being written, against real adapter class names, not guessed here.
2. Whether `FileStore`'s journal file should shard per shop the way `orders.json`'s open decision #1 already flags — same "defer until a real file is large enough to matter" answer applies here too.
3. Whether a second `Store` implementation (SQLite, Redis) ships in this gem or waits for a real consumer that needs one — no evidence either is needed yet.

## Explicit non-goals (this pass)

- No console or admin panel — §22 says it's blocked on the §12/observability reconciliation (already done, §23–25) plus this storage seam, not the other way around; building the read/UI surface is separate work once this lands.
- No scheduler, and no cross-process `idempotency_provider` extraction for `Support::Idempotency` — a related but separate §22 handoff item, not bundled into this one.
- No refactor of `TransactionLog`/`OrderLedger` onto the new `Store` abstraction. They stay exactly as they are; retrofitting them is extra surface this pass doesn't need to touch to ship the journal, and their read/write shapes (reserve-then-commit, keyed-by-id snapshot) don't fit an append-only `Store` cleanly anyway.
- No query/filter API on `PurchaseJournal` (by date range, by shop, ...) — `#each_record`/`#all` only; a real read need should shape that API, not a guess.
