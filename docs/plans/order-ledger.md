# Order Ledger: Durable Local Purchase History

**Status:** planned, not started
**Driver:** proposal for an immutable purchase-history ledger + a re-order engine. Investigation found most of both already shipped — what's actually missing is that nothing persists an `Order` locally, so "history" survives only as long as the remote platform chooses to serve it.

## Context

The original proposal had two parts, `Ledger::LineItem` (snapshot price/currency/tax/fulfillment at purchase time) and `OrderBuilder` (re-order from a historical order ID, re-check stock, re-price, reuse payment context). Reading the code first changed the shape of both.

**The snapshot schema already exists.** `Order` ([value_objects.rb:508](../../portage-ucp/lib/portage/ucp/value_objects.rb#L508)) and `OrderLineItem` ([value_objects.rb:435](../../portage-ucp/lib/portage/ucp/value_objects.rb#L435)) are `Data.define` — immutable by construction — and carry line items, `currency`, `totals`, `fulfillment`, and per-item `status`. Tax is a `Total` with `type: "tax"` ([value_objects.rb:170](../../portage-ucp/lib/portage/ucp/value_objects.rb#L170)), per the UCP schema. `Adapter#reorder`'s own comment already states the posture the proposal asked for: *"order_line_item.json's totals are historical, not live."* A new `Ledger::LineItem` would restate this in a second, divergent vocabulary.

**The re-order engine already exists.** `Adapter#reorder` ([adapter.rb:104](../../portage-ucp/lib/portage/ucp/adapter.rb#L104)) is a documented Portage extension that hydrates a cart from a prior order, re-checks each item's current price and availability, and reports what got dropped via `ReorderResult#unavailable_items`. The reference implementation partitions by availability ([reference_adapter.rb:152](../../portage-ucp/lib/portage/ucp/reference_adapter.rb#L152)); `complete_checkout` re-checks stock again at the moment of charge and raises `OutOfStockError`.

**Post-purchase status already has a vocabulary too.** Refunds, returns, cancellations and disputes are `Adjustment` records ([value_objects.rb:493](../../portage-ucp/lib/portage/ucp/value_objects.rb#L493)) hanging off `Order#adjustments` — `type` is an open string the spec documents as "refund, return, credit, price_adjustment, dispute, cancellation" ([adjustment.json:20](../../portage-ucp/schemas/2026-04-08/schemas/shopping/types/adjustment.json#L20)), and `status` already carries the pending-vs-settled distinction: the reference adapter writes `type: "return", status: "pending"` for a return the merchant hasn't processed yet, against `status: "completed"` for a settled refund or cancellation ([reference_adapter.rb:133-145](../../portage-ucp/lib/portage/ucp/reference_adapter.rb#L133-L145)). "Refunded / returned / cancelled / disputed, and pending while awaiting a confirmed refund" is therefore `Adjustment#type` + `Adjustment#status`, not a new state machine.

**What is actually missing:** `TransactionLog` ([transaction_log.rb:25](../../portage-ucp/lib/portage/ucp/support/transaction_log.rb#L25)) records aggregate `amount`/`currency` per payment dispatch and nothing at line-item level. The `Order` — and with it every adjustment — is only ever a live `get_order` round-trip to the platform. If the merchant edits history, the platform prunes old orders, or the credential's access lapses, the local side holds no record of what was bought at what price, nor of what was later refunded or disputed. That is the gap the proposal was reaching for, and it needs persistence, not a schema.

**Adjustments resolve out-of-band, which is the genuinely new problem.** A `pending` return becomes `completed` when the merchant processes it, days later. A dispute has no originating UCP action at all — there is no `open_dispute` on the adapter, because disputes start at the issuer or gateway and only ever appear as an adjustment on a subsequent `get_order`. So adjustment state can never be captured purely by writing at dispatch time the way a purchase can; it needs an explicit refresh path. This is what makes post-purchase tracking a real phase rather than three extra write sites.

## Non-negotiable constraints

- **Reuse `Order`/`OrderLineItem`/`Adjustment` verbatim.** No parallel ledger vocabulary, and specifically no local enum of refunded/returned/cancelled/disputed states. `Adjustment#type` is an open string by spec and `Adjustment#status` already distinguishes pending from settled; a closed local enum would reject adjustment types a merchant legitimately invents. Every one of these objects already has `to_wire_h`, so persistence is a serialization call, not a mapping layer. A second schema for the same facts is how the two drift.
- **An order's purchase facts are immutable; its adjustments are not.** These are two different durability stories living in one record. Line items, prices and currency are written once and never touched again. Adjustments accumulate and change status over time. Any code path that refreshes adjustments must not rewrite the purchase snapshot from the refreshed payload — that would let a later platform-side edit silently overwrite what was originally paid, which is the exact failure this plan exists to prevent.
- **Snapshot on the settled result, not a re-fetch.** `Checkout#order` ([value_objects.rb:415](../../portage-ucp/lib/portage/ucp/value_objects.rb#L415)) is present on the `result` already in hand at the settle point in `call_and_log_transaction` ([dispatcher.rb:86](../../portage-ucp/lib/portage/ucp/dispatcher.rb#L86)). Re-fetching would reintroduce exactly the live-data dependency this plan exists to remove.
- **Separate file from `transactions.json`.** Payment records and order history have different retention and different read patterns — `completed_since` scans the transaction log on every spend-cap check, and order snapshots would bloat that hot path for no benefit.
- **Inherit the payment-path file conventions**, for the same reasons spelled out at [transaction_log.rb:1-25](../../portage-ucp/lib/portage/ucp/support/transaction_log.rb#L1-L25): `chmod 0600`, `flock`, and **write failures raise rather than being swallowed**. A silently lost order snapshot is an unnoticed hole in the evidence trail. Do not copy the `rescue StandardError; nil` pattern from `history.rb`.
- **Snapshot writes must never fail a settled charge.** This is in direct tension with the constraint above and the tension is the interesting part — see Phase 1.
- **No new payment-token handling.** Tokens are scoped to merchants and `max_amount` at enrollment and revalidated per dispatch (`check_token_scope`, [policy_guard.rb:99](../../portage-ucp/lib/portage/ucp/policy_guard.rb#L99)). A re-order reuses the same `token_ref` and passes through `PolicyGuard` normally. There is no "copy the billing/shipping token context" operation to build, and building one would mean a second path around the gate.

## Phases

### Phase 1 — Order snapshot store

- New `Support::OrderLedger`, modeled closely on `TransactionLog`: `~/.portage/orders.json`, `flock`-guarded, `0600`, raising writes.
- Records `order.to_wire_h` keyed by order id, plus the `idempotency_key` that produced it so a snapshot can be joined back to its transaction record.
- Written at the success branch of `call_and_log_transaction` ([dispatcher.rb:86](../../portage-ucp/lib/portage/ucp/dispatcher.rb#L86)), from `result.order`, alongside the existing `@transaction_log.complete` call. Skip silently when `result.order` is nil — not every completed checkout produces an order.
- **Ordering and failure handling.** Write the snapshot *after* `complete`, and let a snapshot write failure raise only after the transaction record is already settled `complete`. The money has moved by this point; the charge must not be reported as failed because a local history write failed. This deliberately differs from the pre-dispatch reserve, where raising is correct precisely because nothing has been charged yet. Note the distinction in a code comment — it will otherwise read as an inconsistency with `TransactionLog`.
- Specs: snapshot survives a fresh process, a nil `result.order` writes nothing, a write failure surfaces without flipping the transaction record's status.

### Phase 2 — Read path

- `OrderLedger#find(order_id)` / `#all`, plus whatever `portage` subcommand fits the existing CLI shape (likely alongside `portage history`).
- Local snapshot is authoritative for purchase facts. Do **not** silently fall back to a live `get_order` to fill a missing snapshot — that reintroduces the drift this plan removes. Report the gap instead. This rule covers purchase facts only; adjustment freshness is Phase 3's problem.
- Re-order stays on `Adapter#reorder` against the live platform, unchanged. The ledger answers "what did I pay"; `reorder` answers "what can I buy again now." Keeping those separate is the point.

### Phase 3 — Post-purchase adjustments

Resolves what was previously an open decision: the ledger does track refunds, returns, cancellations and disputes, because an order's money story isn't finished at checkout and a purchase record that stops there will disagree with the bank statement.

- **Write on dispatch.** `cancel_order`, `refund_order` and `request_return` ([adapter.rb:74-89](../../portage-ucp/lib/portage/ucp/adapter.rb#L74-L89)) each return an updated `Order`. Persist its `adjustments` to the existing ledger record at each of those three call sites, same non-fatal posture as Phase 1 — a failed history write must not make a succeeded refund look failed.
- **Reconcile for everything else.** Disputes have no originating action, and a `pending` return settles on the merchant's clock, so dispatch-time writes can't be the only source. Add an explicit `OrderLedger#refresh(order_id)` that re-fetches via `get_order` and merges *adjustments only*, leaving the purchase snapshot untouched per the constraint above.
- **Surface what's unresolved.** Any adjustment sitting at `status: "pending"` is money the buyer is owed but hasn't received — an open return awaiting a confirmed refund, or an open dispute. The read path should be able to list exactly these, since they're the records that most need a human to chase. This is the main practical payoff of the phase.
- **No automatic polling in v1.** `refresh` is explicit — invoked by a CLI command or a caller that wants current state. A background poller means a daemon, a schedule, and a per-shop credential lifetime story that none of this plan currently has. Revisit only if manual refresh proves insufficient.
- Specs: a dispatched refund lands on the ledger; `refresh` merges a newly-appeared dispute adjustment without altering stored line-item totals; a `pending` return flipping to `completed` upstream is reflected after `refresh`; listing unresolved adjustments returns exactly the pending ones.

## Open decisions

1. Whether to shard `orders.json` per shop, as Phase 0 considered for transactions. Defer until a real file grows large enough to matter.
2. Whether tax *rates* (as opposed to the tax *amounts* `Total` already carries) are ever needed. Rates are not in the UCP schema, so this means diverging from spec; skip unless something concrete requires it.
3. Whether an adjustment that contradicts the purchase snapshot (a refund exceeding what was paid, say) should be flagged rather than stored quietly. Probably worth a warning eventually; not a v1 blocker.
4. Whether a pending adjustment should ever influence `PolicyGuard`'s spend accounting — a refunded purchase arguably shouldn't count against a rolling cap. Deliberately out of scope: spend state is `TransactionLog`'s, and wiring the ledger into the gate would couple two stores that are currently independent.

## Explicit non-goals (v1)

- No `Ledger::LineItem` or any new snapshot schema — `Order`/`OrderLineItem` are the schema.
- No local status enum for refunded/returned/cancelled/disputed — `Adjustment#type` and `Adjustment#status` are the vocabulary, and `type` stays an open string.
- No `OrderBuilder` service — `Adapter#reorder` is the re-order path.
- No new payment-token context object, and no re-order path that bypasses `PolicyGuard`.
- No local re-pricing or stock simulation from snapshot data — stock and price come from the platform at re-order time, as they do today.
- No dispute *initiation* — disputes originate at the issuer or gateway; the ledger observes them, it does not open them.
- No background reconciliation daemon.
