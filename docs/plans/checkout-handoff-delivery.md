# Checkout Hand-off Delivery — auto-open + notification path

**Status:** Phase 1 (auto-open) and Phase 2 (notification path) shipped. Phase 3 (`--wait`) dropped — no confirmed signal to build against (see Phase 3 section).
**Driver:** today, every path in `Buy` that can't finish a purchase itself (`requires_escalation`, `PaymentPermissionError`, no `--payment-token`) resolves to a `checkout_url` that's just *data* — printed as text in human mode, a bare JSON field in `--json` mode. Nothing pings the shopper or opens anything. That's fine for an agent reading `--json` output itself, but there's no path for "get a human's attention" at all.

## Context

Three dead-end branches all converge on the same hand-off shape (`checkout_report(..., checkout_url: checkout_url_of(checkout), message: "...")`):

- [`escalation_report`](../../portage-cli/lib/portage/cli/buy.rb) — `requires_escalation` from the merchant.
- `permission_denied_report` — `Client::PaymentPermissionError` (this session's work, see `docs/ucp-tool-gating-investigation.md`).
- the no-`--payment-token` branch inside `#complete`.

All three go through the new `checkout_url_of(checkout)` helper (added this session). `cli.rb#format_report` (~line 604) prints `checkout: <url>` as a line of text; `execute_buy` (~line 195) prints the whole report as JSON under `--json`. Neither does anything active with the URL.

The one existing precedent for "notify an out-of-band channel and wait" in this codebase is `Portage::Ucp::Confirmer::Webhook` ([confirmer.rb](../../portage-ucp/lib/portage/ucp/confirmer.rb)) — POSTs to a `confirm_url`, polls a `status_url`, and is explicit in its own comments that "the actual notification transport is the caller's job" (Slack/WhatsApp/whatever). That's the shape to reuse, not reinvent, for a notification path here. It also reuses `Support::HttpClient`, already in core with zero new runtime dependency.

For config precedent: this repo has two established patterns and no clear rule for which a new toggle should follow —
- **Env vars** for buyer-identity/behavior flags read once per invocation: `PORTAGE_AGENT_PROFILE`, `PORTAGE_SHIP_*` ([shipping_profile.rb](../../portage-cli/lib/portage/cli/shipping_profile.rb)), `PORTAGE_CURRENCY`/`PORTAGE_LANGUAGE` ([buyer_context.rb](../../portage-cli/lib/portage/cli/buyer_context.rb)).
- **`~/.portage/*.json`** for durable, editable config: `Policy` ([policy.rb](../../portage-ucp/lib/portage/ucp/policy.rb)) via `portage policy show/set`, `PaymentMethods` ([payment_methods.rb](../../portage-cli/lib/portage/cli/payment_methods.rb)).

This is an open decision below, not settled here.

## Non-negotiable constraints

- **`portage-ucp` core gains nothing.** This is entirely a `portage-cli` UX concern — hand-off is about what happens *after* Dispatcher/PolicyGuard/Confirmer have already produced an outcome, not a protocol or payment-safety concern. Don't touch `Dispatcher`/`PolicyGuard`/`Confirmer`/`TransactionLog`.
- **Default off, opt-in only.** Auto-opening a browser or firing a webhook without being asked is a surprise a headless/server run (this repo explicitly supports a no-display `EnvBackend` payment tier) must never hit. `portage buy` today never launches anything; that must stay the default.
- **Best-effort, never fails the buy.** A failed browser-open or failed webhook POST must not raise out of `Buy#call` — the checkout itself is a real, correct outcome (created, or correctly escalated) independent of whether the hand-off delivery succeeded. Report the delivery failure as data on the result, the same way a lost journal write is reported as a `nil` skip rather than flipping a settled charge to failed (`Dispatcher#call_and_log_transaction`'s posture).
- **Never fire on `--dry-run`.** A dry run creates a real checkout but never attempts completion — opening a browser or notifying someone over a preview run would be actively wrong. Hand-off only fires from the three real dead-end paths (`escalation_report`, `permission_denied_report`, the no-token branch), never from `dry_run_report`/`confirmation_needed_report`.
- **The URL still always gets printed**, regardless of auto-open/notify settings — auto-open is additive, not a replacement for the existing visible text/JSON output. A user who doesn't trust an automated open should still be able to see and click the link themselves.
- **No new runtime dependency for the browser-open.** Every other "shell out" spot in this repo (`PaymentMethods::KeychainBackend`, `SecretServiceBackend`) hand-rolls `system(...)` rather than pulling in a gem (e.g. `launchy`) for something the OS already provides (`open`/`xdg-open`/`start`). Match that.

## Phases

### Phase 1 — auto-open config

- New `Portage::Cli::CheckoutHandoff` (or fold into an existing small class — decide against real code, not here), mirroring `BuyerContext.from_env`'s shape: reads a toggle (see Open decision #1) and exposes `#auto_open?`.
- Platform dispatch: `RbConfig::CONFIG["host_os"]` picks `open` (macOS) / `xdg-open` (Linux) / `start` (Windows), shells out via `system(cmd, url)` (never `system("#{cmd} #{url}")` — no string interpolation into a shell, avoid command injection from a URL a merchant server controls). Wrap in `rescue StandardError` → log, don't raise (matches "best-effort" constraint above).
- Wire into `Buy` at exactly the three dead-end sites (`escalation_report`, `permission_denied_report`, the no-token branch in `#complete`) via one shared private method (e.g. `#hand_off(checkout_url)`) rather than duplicating the open-attempt three times — same instinct that produced `checkout_url_of` this session.
- Specs: auto-open disabled (default) never calls `system`; enabled calls the right platform command; a `system` failure doesn't raise and the buy result is unaffected; `--dry-run` never triggers it regardless of the toggle.

### Phase 2 — notification path

- New `Portage::Cli::Notifier`, reusing `Portage::Ucp::Support::HttpClient` (already a core dependency via `Confirmer::Webhook`, so no new gem) to POST a JSON body when a hand-off fires: `{event: "checkout_handoff", reason: "requires_escalation" | "permission_denied" | "no_payment_token", checkout_url:, checkout_id:, source:, totals:}`.
- Configured via a webhook URL (env var or flag, same open decision as Phase 1's toggle). No built-in email/SMS sender — a consumer points the webhook at Slack's incoming-webhook URL, Zapier, their own relay, whatever; same "the transport is the caller's job" posture `Confirmer::Webhook`'s own comments already state.
- Failure is caught, never raised, and surfaces as a `notify_error` field on the report — same non-negotiable as Phase 1.
- Specs: webhook fires with the right body on each of the three dead-end paths; a POST failure doesn't raise, surfaces on the report; disabled (no URL configured) never attempts a request.

### Phase 3 — dropped

A `--wait` flag that blocks `portage buy` until the shopper finishes in their browser. Would need either a merchant-side webhook back to this process (Shopify doesn't offer one for this today, unconfirmed either way) or polling `get_checkout` until `status` moves off `requires_escalation`. Dropped rather than deferred: no live evidence either signal exists, and building against an assumed platform behavior that was never actually checked is the exact mistake `docs/design-log.md` §42 already paid for once. Revisit only if a confirmed signal shows up.

## Open decisions — resolved

1. **Config surface**: both. Precedence `--auto-open`/`--notify-webhook` CLI flag > `PORTAGE_AUTO_OPEN_CHECKOUT`/`PORTAGE_NOTIFY_WEBHOOK_URL` env var > `~/.portage/config.json` (`auto_open_checkout`/`notify_webhook_url`). CLI flag always available as a one-off override regardless of which of the other two is set.
2. **Report shape**: `handoff: {url:, opened: true|false, notified: true|false, notify_error: nil|"..."}` sub-hash. Existing `checkout_url`/`message` fields untouched — `--json` consumers reading only `checkout_url` today are unaffected.
3. **URL trust before auto-opening**: `URI.scheme == "https"` check only. No same-host check against the store's own domain for this pass.

## Explicit non-goals (this pass)

- No SMS/email built-in senders — webhook only.
- No blocking/polling for shopper completion (Phase 3, explicitly deferred pending a confirmed signal).
- No change to `Dispatcher`/`PolicyGuard`/`Confirmer`/`TransactionLog` — purely a post-hoc UX layer on already-decided outcomes.
- No auto-open/notify on `--dry-run` or the plain "awaiting `--yes` confirmation" path — only the three real dead-end completions.
