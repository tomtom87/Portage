# Agentic Payments: Stored Tokens, Policy, Confirmation

**Status:** planned, not started
**Driver:** focus group feedback — agent reaches payment step in `portage buy` and dead-ends with "No --payment-token given" ([portage-cli/lib/portage/cli/buy.rb:265-268](../../portage-cli/lib/portage/cli/buy.rb#L265-L268))

## Context

`portage-cli buy` has no way to store or reuse a payment token today. Every purchase needs `--payment-token` passed fresh on the command line, so an autonomous agent can build a cart but never complete checkout unsupervised. The focus group wants this closed: store payment info once, reuse it, one-click checkout.

Doing this safely means the CLI must never see raw card data (see `PaymentTokenGuard`, `adapter.rb:292` — tokens must come from a payment handler / AP2 exchange, never a raw PAN), and that removing the "missing token" dead-end also removes the only thing currently standing between an autonomous agent and a real charge. So this plan ships storage/reuse *together with* the guardrails (spend cap, allowlist, confirmation), not as a follow-up.

## Non-negotiable constraints

- **No raw PAN ever touches CLI memory or disk.** Card entry happens on the gateway's own hosted page; the CLI only ever handles the resulting token.
- **Policy gate lives in `portage-ucp/lib/portage/ucp/dispatcher.rb`**, next to the existing `PaymentTokenGuard` call (`dispatcher.rb:30`), not in portage-cli. Anything bypassing the CLI (MCP server, client gem direct) must still be gated.
- **Transaction log writes are fatal on the payment path.** The silent `rescue StandardError; nil` pattern in `history.rb:67-69` / `probe_cache.rb` / `search_backends.rb` must NOT be copied for payment records — a swallowed write means the cap/dedup state silently drifts and a later run can overspend.
- **Reserve-then-commit accounting.** Write the transaction record as `pending` *before* dispatch, settle it after. A crash mid-charge must leave evidence, not silence.
- **Local policy guards agent mistakes, not a compromised agent.** Anyone running as the local user can edit the policy file. State this plainly in the README; recommend issuer-side limits (virtual cards, e.g. Stripe Issuing / Privacy.com) as the real backstop.

## Phases

### Phase 0 — Durable idempotency + transaction log (foundation)

- Replace the per-process mutex table in `portage-ucp/lib/portage/ucp/support/idempotency.rb` with a pluggable store interface. Default impl: file + `flock` (works for CLI single-host use). Must be injectable (Redis/SQLite) for server/multi-process deployments — this was the actual complaint (durability across restarts and processes), not just "in-memory is bad."
- New `~/.portage/transactions.json` (or sharded per-shop), written via the existing `FileUtils.mkdir_p` + `File.write` convention from `history.rb`, but:
  - `chmod 0600` on write (no existing store in this repo does this — new convention, note it explicitly in code comments).
  - Write failures raise, not swallow, on this path only.
  - Record shape: `{idempotency_key, shop, checkout_id, status: pending|complete|failed, policy_decision, confirmation_outcome, payment_token_ref, amount, currency, created_at, completed_at}`.
- No UI changes yet — this phase is infrastructure other phases depend on.

### Phase 1 — Storage & reuse

- Keychain-backed payment method store, three tiers, no homegrown crypto or fallback file store:
  1. macOS → Keychain (shell out to `security`)
  2. Linux with Secret Service (D-Bus, GNOME Keyring/KWallet) → `libsecret`/`secret-tool`
  3. Headless (no D-Bus session — the common case for a server-deployed agent) → **no local storage**; token comes from an env var, consistent with how `resolver.rb` already handles platform credentials.
- `portage payment` subcommands: `list`, `set-default`, `remove`, `freeze` (blocks spend, keeps enrollment), `revoke` (deletes token).
- Enrollment flow: new browser-handoff flow shaped like the existing `requires_escalation` pattern (`buy.rb:278-282`) — CLI opens a gateway-hosted setup page, user enters card there, CLI polls for the resulting token. This is a new flow modeled on the existing one, not literally reused code — the escalation links come from the platform adapter's checkout response, not from us.
- `buy.rb:265` dead-end becomes `@payment_token ||= PaymentMethods.default` — `--payment-token` stays as an explicit override.
- No "arm" step (e.g. `portage payment arm --ttl 1h`) — token is permanently spendable once enrolled, gated only by Phase 2 policy + Phase 3 confirmation. This is safe only because confirmation defaults to **on**; if an auto-approve-under-$X threshold is ever added, it must be opt-in, bounded by the Phase 2 velocity limit, and counted against the daily cap.

### Phase 2 — Policy engine (in-core, in `portage-ucp`)

- `PolicyGuard` module beside `PaymentTokenGuard`, called from `dispatcher.rb` before dispatch of any mutating/payment action.
- Public API kept small and stable since `portage-ucp` is a published gem: roughly `PolicyGuard.check!(amount:, currency:, merchant:, token_ref:)`. Internal policy representation (file format, rule schema) stays private so it can evolve without a semver-major bump.
- Checks, in order:
  1. **Spend cap** — per-transaction and/or rolling window, explicit currency (no implicit conversion — reject mismatches rather than guess).
  2. **Velocity limit** — max transaction count per hour/day, independent of amount. Catches a retry-loop agent making many small purchases each individually under cap.
  3. **Merchant allowlist** — exact host or registrable domain match only. No substring matching (`evil-shopify.com` must not pass an allowlist for `shopify.com`).
  4. **Per-token scope** — constraints bound at enrollment time to a specific token (card X can only spend at merchants Y, up to Z) — the local analogue of an AP2 mandate.
- `portage policy show` / `portage policy set` CLI commands to manage the above.
- All decisions (pass/block/reason) recorded on the Phase 0 transaction record.

### Phase 3 — Confirmation

- `Confirmer` interface: given `{amount, currency, merchant, idempotency_key}`, returns approve/deny.
- Terminal y/n implementation ships first (blocks CLI process on stdin).
- Fail-closed timeout: no answer within N minutes = deny, never allow. Handle checkout expiry mid-wait.
- Interface is transport-agnostic by design so WhatsApp/Slack/etc. can implement it later as separate gems — core has zero knowledge of those transports. No crypto-signing of the confirmation payload in this phase (overkill for a synchronous terminal prompt); the interface just carries the fields future async transports would need to bind a reply to a specific request.
- Confirmation outcome recorded on the transaction record (Phase 0).
- **Shipped (design-log §35):** `Confirmer::Webhook` — POST + poll a status
  endpoint (or a caller-supplied `wait:` callback for push transports),
  fail-closed on timeout with its own longer default than `Terminal`'s
  120s. The out-of-band notification transport itself (Slack, WhatsApp)
  stays a consumer's job; core only speaks HTTP.

## Open decisions (revisit if they change scope)

1. Whether Phase 2 ends up needing its own gem (`portage-ucp-policy`) if the ruleset grows — start in-core, split out only if it earns it.
2. Windows Credential Manager as a fourth Phase 1 storage tier — not needed unless requested.
3. Whether an auto-approve-under-$X threshold ever gets built (see Phase 1 note on "arm") — out of scope for v1.

## Explicit non-goals (v1)

- No encryption-at-rest scheme invented for headless deployments — defer to the platform's existing secret manager (env var in, nothing stored locally).
- No cryptographic binding of confirmation replies.
- No "arm" / time-boxed activation step.
- No support for raw card entry inside the CLI process, ever.
