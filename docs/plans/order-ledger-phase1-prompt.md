# Prompt for next coding agent: Order Ledger — Phase 1

Read `docs/plans/order-ledger.md` in full first — it has the context, constraints, and later phases. This prompt covers Phase 1 only.

## Task

Implement Phase 1 ("Order snapshot store") from the plan above, in the `portage-ucp` gem.

## What exists already — read before writing anything

- `Portage::Ucp::Order` and `Portage::Ucp::OrderLineItem` ([value_objects.rb:508](../../portage-ucp/lib/portage/ucp/value_objects.rb#L508), [value_objects.rb:435](../../portage-ucp/lib/portage/ucp/value_objects.rb#L435)) are immutable `Data.define` objects with a working `to_wire_h`. This is the schema — do not invent a parallel one.
- `Support::TransactionLog` ([transaction_log.rb](../../portage-ucp/lib/portage/ucp/support/transaction_log.rb)) is the file-store pattern to copy: `flock`-guarded, `0600`, writes raise instead of swallowing errors. Read it fully before writing `OrderLedger` — same shape, same conventions, different file.
- `Dispatcher#call_and_log_transaction` ([dispatcher.rb:86](../../portage-ucp/lib/portage/ucp/dispatcher.rb#L86)) is the settle point. On success it already has `result` (a `Checkout`) in hand and calls `@transaction_log.complete(...)`. `Checkout#order` ([value_objects.rb:415](../../portage-ucp/lib/portage/ucp/value_objects.rb#L415)) is the `Order` to snapshot — it may be `nil`.

## Task

- New `Portage::Ucp::Support::OrderLedger`, file-backed at `~/.portage/orders.json`, same `flock`/`0600`/raising-write conventions as `TransactionLog`. Keep the public surface minimal: something like `#record(idempotency_key:, order:)` and `#find(order_id)`.
- Store `order.to_wire_h` keyed by `order.id`, plus the `idempotency_key` of the dispatch that produced it (so a snapshot can be joined back to its `TransactionLog` record later).
- Wire it into `call_and_log_transaction`'s success path, right after `@transaction_log.complete`. Skip the write silently when `result.order` is `nil` — not every completed checkout produces an order (e.g. cart-only flows).
- **Ordering and failure handling — read this twice, it's the one place this diverges from `TransactionLog`'s posture:**
  - Write the order snapshot *after* `@transaction_log.complete(status: "complete", ...)` has already succeeded, not before and not interleaved.
  - If the snapshot write itself raises, let it propagate — but only *after* the transaction record is already durably `complete`. The money has moved by this point in the flow; a lost local history write must never cause the charge to be reported as `failed` or leave the transaction record in a `pending`/ambiguous state.
  - This is the opposite instinct from `TransactionLog#reserve`, where raising *before* dispatch is correct because nothing has been charged yet. Here the raise is correct only because it happens strictly after settlement. Put a comment at the call site explaining this — it will otherwise read as an inconsistency with the reserve-then-commit pattern Phase 0 established.
- Do not touch `cancel_order`, `refund_order`, `request_return`, or anything about `Adjustment` — that's Phase 3, out of scope here.
- Do not build a read/CLI surface — that's Phase 2. `#find` existing on the class is fine (useful for specs); no subcommand.

## Specs to add

1. Recording an order, then reading it back in a fresh `OrderLedger` instance pointed at the same path, returns the same data (mirrors `TransactionLog`'s "survives a fresh process" spec).
2. `result.order` being `nil` at the dispatcher's settle point writes nothing to `orders.json` and does not raise.
3. A write failure (e.g. stub the file write to raise) propagates to the caller, but only after asserting the corresponding `TransactionLog` record is already `status: "complete"` — i.e. simulate the failure and check the transaction record's state before the exception is allowed to surface, to prove the ordering constraint above actually holds and not just that it's documented.
4. A normal successful dispatch with an order present ends up with both a `complete` transaction record and a matching order snapshot, joinable by `idempotency_key`.

## Explicit non-goals for this task

- No `Ledger::LineItem` or any schema besides the existing `Order`/`OrderLineItem`.
- No adjustment tracking (refund/return/cancellation/dispute) — Phase 3.
- No read-path CLI command (`portage history`-style or otherwise) — Phase 2.
- No re-order changes — `Adapter#reorder` is untouched by this plan entirely.
- No sharding of `orders.json` per shop — open decision, not this task.

## Before you start

- Confirm current behavior of `call_and_log_transaction` and `TransactionLog` with a quick read of `dispatcher.rb` and `support/transaction_log.rb` in full — the plan doc's line references may have drifted since it was written.
- Check `CHANGELOG.md` at repo root for version-bump conventions before touching gemspec versions, if that turns out to be needed.
