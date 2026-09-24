# Handoff Reconcile: Did the Shopper Finish the Checkout?

**Status:** Phases 1–2 shipped (pending-handoff record, `HandoffReconciler`, `portage orders reconcile`, `handoff_spend_mode`). Phase 0's live signal check was **not run** — no live store credentials available in that session — so Phases 1–2 were built on the plan's own default assumption (`completed` is observable) rather than a confirmed one; see design-log §44 before relying on this against a real store. Phase 3 (`--wait`/NDJSON/extra notify channels) and Phase 4 (WebMCP) not started.
**Driver:** every checkout that `portage buy` can't finish itself ends up with the shopper in a browser via `handoff_report` ([buy.rb:695](../../portage-cli/lib/portage/cli/buy.rb#L695)). After that, Portage knows nothing. It doesn't know whether the shopper paid, abandoned the checkout, or let it expire, and a purchase the shopper completes never reaches `transactions.json`, `orders.json` or the journal. In practice nearly every real checkout needs a human to finalize it, so this is the common path, not an edge case.

## Context

**Every handoff has one exit.** Six outcomes go through `handoff_report`: `requires_escalation`, `permission_denied`, `no_payment_token`, `policy_blocked`, `low_confidence` and `checkout_mismatch`. The report already carries `checkout_id`, `checkout_url` and a `handoff:` sub-hash ([buy.rb:712](../../portage-cli/lib/portage/cli/buy.rb#L712)). That gives us one natural place to record a pending handoff.

**The protocol already has a completion signal.** The checkout `status` enum ends in `completed` or `canceled` ([checkout.json:65](../../portage-ucp/schemas/2026-04-08/schemas/shopping/checkout.json#L65)). `expires_at` defaults to 6h from creation when the store doesn't send one ([checkout.json:104](../../portage-ucp/schemas/2026-04-08/schemas/shopping/checkout.json#L104)). `Client::Session#get_checkout` and `#get_order` exist ([session.rb:93](../../portage-ucp-client/lib/portage/ucp/client/session.rb#L93), [:121](../../portage-ucp-client/lib/portage/ucp/client/session.rb#L121)).

**Why `checkout-handoff-delivery.md` Phase 3 was dropped, and why this plan can still go ahead.** That plan dropped `--wait` because "no live evidence either signal exists". That's still true. Nobody has checked whether a real store's `get_checkout` reports `completed` after the shopper pays at its `continue_url`. This plan therefore starts with Phase 0, a live check, and every later phase depends on its result. It is the §42 lesson again: verify the platform's behaviour first, then build.

**Completion hands back a stub, not an order.** `Checkout#order` is an `order_confirmation` stub (id, permalink, label). It is not a full `Order` (see the comment in [purchase_journal.rb](../../portage-ucp-journal/lib/portage/ucp/journal/purchase_journal.rb)). `OrderLedger#record` wants a real `Order` (`to_wire_h`). The order-ledger plan's rule is to snapshot the settled result and not re-fetch. That rule assumes a settled result is already in hand, which a handoff never has. For a handoff, a `get_order` call is the first time we see the order, not a re-fetch. The Order Ledger's no-re-fetch constraint doesn't apply here; state that in a code comment.

**Spend caps only count `complete` records.** `TransactionLog#completed_since` ([transaction_log.rb](../../portage-ucp/lib/portage/ucp/support/transaction_log.rb)) feeds `PolicyGuard`'s rolling cap and velocity limit ([policy_guard.rb:59](../../portage-ucp/lib/portage/ucp/policy_guard.rb#L59)). Today a shopper-paid handoff never lands there, so caps undercount real spend.

## Decisions (from interview, 2026-09-24)

1. **Do handoff reconcile first.** Order refresh/`open` comes after it (the order-ledger plan's Phase 3). Email and payment tokens come later.
2. **Refresh both ways:** `portage buy --wait` for interactive runs, plus an explicit `portage orders reconcile` that cron or launchd can run. No daemon.
3. **Email stays agent-side.** The `shop-via-ucp` skill tells the agent to use its own mail connector (e.g. Gmail MCP) to find confirmations. Portage gets no email code.
4. **Shopper-paid orders count toward caps by default, and this is configurable.** Mode `block` is the default, with `warn` and `precheck` as alternatives (see Phase 2).
5. **`--wait` gives up after 30 minutes by default** (`handoff_wait_timeout`), or earlier if the store's `expires_at` comes first. It's configurable, and `off` removes the ceiling so the wait runs to the store's expiry (up to the schema's 6h default).
6. **WebMCP checkout supports both routes, configurable**: stop at the express-pay button, or complete with a payment token. Deferred to Phase 4.
7. **Every notify channel is available, each configurable**: webhook (on by default when a URL is set), journal entry, macOS notification, terminal. The calling agent is always told via **NDJSON events on stdout** under `--wait --json`.
8. **Settings use the existing `Setting` precedence**: flag > `PORTAGE_*` env var > `~/.portage/config.json`.
9. **The transaction log stays DRY and robust.** Handoff records use the existing `reserve`/`complete` path, not a parallel one. Cap exclusion lives in one core place that every store and every caller (CLI and MCP server) goes through (see Phase 2).

## Non-negotiable constraints

- **The URL is still always printed. The handoff itself never waits on reconcile.** Recording a pending handoff is best-effort, like `hand_off` today. A failed pending write goes on the report as a warning and never fails `Buy#call`.
- **Never on `--dry-run`**, same rule as `hand_off`.
- **Settle only on a `completed` status the store actually reports.** Never infer success from a vanished checkout, a 404, or an expiry with no answer. Those end as `unknown`, not `complete`. A false `complete` inflates spend caps. A false `failed` hides a real charge. `unknown` hides neither.
- **Idempotent reconcile.** Two runs (cron plus `--wait`, or two cron runs overlapping) must not settle the same handoff twice or write two ledger or journal entries. The key is the existing `portage-buy:<host>:<checkout_id>`. Settling a record that is already terminal does nothing.
- **Purchase facts in the ledger stay immutable** (order-ledger constraint). Reconcile writes an order snapshot once and never overwrites it.
- **Core changes stay minimal, additive and in one place.** `TransactionLog#reserve`/`#complete` accept a fixed allowlist of optional attributes (`OPTIONAL_ATTRIBUTES = %w[settled_by handoff_reason store_url expires_at resolution counts_toward_caps]`), and reject unknown keys with `ArgumentError`. There are no new `reserve_handoff`/`settle_handoff` methods: a handoff is a transaction record with extra attributes. Nothing in `Dispatcher`/`PolicyGuard`/`Confirmer` changes.
- **Old records keep their meaning.** A record without the new fields reads exactly as today: `settled_by` absent means agent/dispatcher, `counts_toward_caps` absent means true. No migration, no rewrite of existing `transactions.json` files.
- **Reconciling needs the store again.** A later process has to re-discover the store from the saved store URL. It uses the same `UserAgent`/agent profile as `buy`, and the same `store` proxy route ([proxy-support.md](proxy-support.md)). It must not assume the old session or its credentials still exist.

## Phases

### Phase 0: Live signal check (gates everything else)

- Run a real handoff by hand against at least one native-UCP Shopify store and one other platform. Poll `get_checkout(checkout_id)` before payment, during it, and after it.
- Record in `docs/design-log.md` (new §):
  - which statuses we actually see;
  - whether `order` shows up on the completed checkout;
  - whether `get_checkout` still answers after completion or starts returning not-found;
  - whether an anonymous session can read a checkout that the shopper completed in the browser;
  - the real `expires_at` values.
- **Exit criteria:**
  - If `completed` is observable, go ahead as planned.
  - If the checkout goes not-found after payment, Phase 1's "gone" branch becomes the main path. Fall back to `get_order`/`list_orders` via platform credentials, or to the agent-side email step. Re-plan before building Phase 1.
  - If there's no signal at all, stop. The plan becomes "record pending handoffs and leave resolution to the agent's email check".

### Phase 1: Pending handoff record + `portage orders reconcile`

- **Record at handoff.** `hand_off` reserves a TransactionLog record under the existing key shape:
  - `status: "pending"`
  - `settled_by: "shopper"` (new optional field; `nil` means agent/dispatcher, as today)
  - `payment_token_ref: nil`
  - `checkout_id`, `shop`, `amount`, `currency` from the checkout
  - `handoff_reason` = the outcome
  - `store_url` and `expires_at`
- **Why reuse TransactionLog** instead of a new store: a shopper-paid purchase is spend, and `PolicyGuard` already reads spend from there. A second store means caps have to join two files. Pending records don't count toward caps (only `complete` does), so recording at handoff changes no cap maths until something settles.
- **Keep them apart from crash evidence.** Dispatcher's own crash-evidence `pending` records have `settled_by: nil`. Reconcile only touches `settled_by: "shopper"` records.
- **New `Portage::Cli::HandoffReconciler`** (portage-cli):
  - Input: one pending record.
  - Re-discovers the store and calls `get_checkout`, then maps the result:

    | `get_checkout` result | Settles as |
    |---|---|
    | `completed` | `complete` |
    | `canceled` | `failed` |
    | past `expires_at` with no terminal status | `failed`, reason `expired` |
    | still in progress (`incomplete`, `requires_escalation`, `ready_for_complete`, `complete_in_progress`) | stays pending |
    | not-found, or a transport error | stays pending; after `expires_at`, settles `failed`, reason `unknown` |

  - `TransactionLog::TERMINAL_STATUSES` is `complete|failed` only. So `unknown` lives in a `resolution` field, not a new status. Adding a status would change what `completed_since` means.
  - Takes the amount from the checkout the store reports as `completed`, not from the handoff-time snapshot. The shopper may have changed quantity or shipping in the browser.
  - On `complete` with an `order.id`: calls `get_order` and records `OrderLedger#record(idempotency_key:, order:)`, then writes the journal entry. If `get_order` fails, keep the stub id on the transaction record and warn. Never block the settle on this.
- **The journal needs a hash-to-value-object step.** `PurchaseJournal#record_checkout` is duck-typed against `Checkout` objects, but the CLI holds hashes. Rebuild the value objects from the wire hash with `Checkout.from_h`-style construction. Don't build a second, parallel entry shape.
- **`portage orders reconcile [--checkout ID] [--json]`**:
  - reconciles every `settled_by: "shopper"` pending record, or just the one named;
  - prints one result per record;
  - is safe to run from cron (see idempotency constraint).
- **Specs:**
  - A handoff writes a pending shopper record.
  - `--dry-run` writes nothing.
  - `completed` settles `complete` with the store's amount, then snapshots the ledger and journal exactly once.
  - `canceled` and expired settle `failed`.
  - Not-found before expiry stays pending.
  - Two concurrent reconciles settle once (flock).
  - A failed pending write at handoff surfaces as a warning and the handoff still succeeds.

### Phase 2: Spend-cap modes for shopper-paid purchases

Setting `handoff_spend_mode`, via flag, env var or config:

| Mode | Behaviour |
|---|---|
| `block` (default) | A settled shopper purchase counts like any other `complete` record. If it pushes the rolling window past the cap, the next *agent* completion is refused by the existing rolling cap. The shopper's own purchase is never blocked: it already happened. The notify payload says the cap is now exhausted. |
| `warn` | Recorded, but excluded from cap and velocity maths. Notifies when it would have pushed spend over the cap. |
| `precheck` | `block`, plus: at handoff time, run `PolicyGuard.check!` against the checkout total. If it would exceed the cap, the handoff still happens and the URL is still printed, but auto-open is suppressed and the report and notify payload carry `over_cap: true` with the reason. The human decides with that in front of them. |

**How `warn` excludes records (decided: core field, filtered once).**
- A `warn`-mode settle writes `counts_toward_caps: false` on the record.
- `TransactionLog#completed_since` filters those out **in the `TransactionLog` wrapper, not in each `Store`**. So `FileStore` and any custom Redis/SQLite store get the same behaviour without re-implementing it, and every caller (CLI, the MCP server, `Dispatcher`) sees the same numbers. A CLI-side filter was rejected: it would repeat the rule, and the MCP-server path would miss it.
- The mode applies when the record settles, not when it's read. Switching `handoff_spend_mode` later doesn't retroactively change past records; the record states what was decided at the time.
- Specs: the `FileStore` and a minimal in-memory `Store` return the same `completed_since` results; a record with no `counts_toward_caps` field still counts; an unknown optional attribute raises.

`policy_blocked` handoffs under `block`/`precheck`: the human is explicitly overriding the cap by paying. Count it anyway, since that is what the money did, and mark the notify payload `cap_overridden_by_shopper: true`.

Specs: one per mode × {under cap, over cap}; `policy_blocked` override counted and flagged.

### Phase 3: `--wait` and notifications

- **`portage buy --wait`** (and `--wait-timeout DURATION`):
  - After a handoff, poll through `HandoffReconciler` with backoff (2s → 30s, with jitter) until a terminal result or the deadline.
  - Deadline = `min(checkout expires_at, handoff_wait_timeout)`. `handoff_wait_timeout` defaults to `30m` (flag `--wait-timeout`, env `PORTAGE_HANDOFF_WAIT_TIMEOUT`, config `handoff_wait_timeout`). The value `off` (or `0`) removes the ceiling, leaving only the store's `expires_at`.
  - Ctrl-C or the deadline leaves the record pending for a later `portage orders reconcile`. Never settle on interrupt.
- **Tell the calling agent (NDJSON).** With `--wait --json`, stdout switches to newline-delimited JSON:
  - `{"event":"handoff","checkout_id":…,"checkout_url":…,"reason":…}`
  - `{"event":"handoff_status","status":"incomplete",…}`, only when the status changes
  - `{"event":"handoff_settled","result":"complete|failed","resolution":…,"order_id":…,"amount":…}`
  - the final report object last

  Plain `--json` without `--wait` keeps today's single-object output byte-for-byte. The NDJSON mode is opt-in, so existing parsers don't break.
- **Notify channels** when a result settles, from `--wait` or `orders reconcile`. Setting `reconcile_notify` is a comma list, default `webhook`:

  | Channel | What it does |
  |---|---|
  | `webhook` | existing `Notifier`, event `checkout_reconciled` |
  | `journal` | the Phase 1 journal write; recommended always on, and separate from notify only for the "did it complete" line item |
  | `macos` | `system("osascript", "-e", …)` in array form. The message is built from fixed strings plus escaped merchant and amount, never raw merchant text. Opt-in. |
  | `terminal` | prints a line (always on under `--wait`) |

  All best-effort. A failure lands on the result as `notify_error`, same as `hand_off`.
- **Specs:**
  - The poll ends on each terminal status and at the deadline.
  - The deadline is honoured when shorter than `expires_at`; the 30m default applies when nothing is configured; `off` waits until `expires_at`.
  - Ctrl-C leaves the record pending.
  - The NDJSON sequence shape is correct.
  - Plain `--json` output is unchanged.
  - Each channel fires only when configured.
  - The osascript arguments can't be injected via the merchant name.

### Phase 4: WebMCP checkout completion (sketch; plan in detail after Phase 3)

Setting `webmcp_checkout_mode`:

- **`express_stop`** (default). The agent drives the page's WebMCP tools (outbound transport, `portage-ucp-webmcp`) to build the cart and set shipping, and stops before payment. The shopper finishes with the page's own Apple Pay or PayPal button. That counts as a handoff, so reason `express_stop` feeds Phases 1–3 unchanged. Browser autofill and Keychain cards are never touched: they're gated on a user gesture by design.
- **`token`**. If the page exposes `complete_checkout` and accepts a payment-handler token, the agent calls it with the enrolled token reference. It goes through `PolicyGuard` and a non-terminal `Confirmer`. Prerequisite: `Mcp::Server.build` needs a way to swap in a different `Confirmer` ([webmcp README § complete_checkout](../../portage-ucp-webmcp/README.md)), and PayPal/Stripe agent-token enrollment has to exist in `portage payment enroll`. The Keychain stores the token reference, never the card.
- Today `portage buy` has no WebMCP path at all. Wiring the outbound transport into `Buy`'s discovery order is Phase 4's first step.

## Open decisions

1. ~~How `warn` excludes records~~: resolved, core field filtered in the `TransactionLog` wrapper (Phase 2).
2. ~~`--wait` ceiling~~: resolved, 30m default, configurable, `off` to disable.
3. Is reason `unknown` (vanished checkout, never confirmed) worth an opt-in fallback to the platform adapter's `get_order`/list when credentials are present? It depends on what Phase 0 finds.
4. Does `precheck` ever withhold the URL? Currently no, since the URL is always printed.
5. Should `portage orders reconcile` also run the order-ledger Phase 3 adjustment refresh in the same pass, or stay a separate `orders refresh`? Separate keeps each command's job clear; combined means one cron line.

## Explicit non-goals

- No email reading in Portage. It's agent-side, via the skill.
- No background daemon. Cron/launchd plus explicit commands only.
- No settling `complete` without a store-reported `completed` status.
- No change to plain `--json` output.
- No use of browser autofill or Keychain-stored cards, ever.
- No new runtime gem dependency (backoff, NDJSON and osascript are all stdlib or a shell-out).
