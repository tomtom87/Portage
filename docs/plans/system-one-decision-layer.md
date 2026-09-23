# System One decision layer (Jev / Layla)

**Status:** built — `portage-ucp-decision` (new gem). All four
responsibilities below exist as typed decisions with real logic: ranking,
the policy-check wrapper (plus a `risk_signals:` gate), escalation (literal
`requires_escalation` plus an ambiguous-signal case), and confidence gating
via two swappable model backends (`ModelBackends::Jev`, `ModelBackends::Laya`).
Still not wired into the agent loop, `portage-cli`, or
`skills/shop-via-ucp.md` — those keep their current scattered logic until a
caller actually switches over.

**Driver:** the agent loop, the transport (`WebMCP`/MCP/native UCP), and the
commerce backend (`Adapter`) each have a clear owner in this repo already.
What doesn't have an owner is the judgment calls in between — which offer to
pick among several, whether to hand off to a human or keep going, whether a
result is confident enough to act on unattended, whether a spend is even
allowed before it's attempted. Today those calls are scattered: some live in
skill instructions the agent loop happens to follow (`skills/shop-via-ucp.md`
guardrail 2), some in `portage-cli` (`Buy#escalation_report`,
`CheckoutHandoff`), some in `portage-ucp` (`PolicyGuard`, `Confirmer`). None of
them are a typed decision a caller can inspect or test against — they're
control flow, not data.

## Shape

```
Agent loop
  → System One layer (Jev / Layla)   ← typed decisions + confidence
  → Portage UCP client / Adapter     ← catalog, cart, checkout, hand-off
  → WebMCP / MCP / native UCP        ← how the tools are reached
```

This sits **above** the Adapter, not inside it. The Adapter's contract
(`Portage::Ucp::Adapter`, `docs/design-log.md` §3) stays protocol-shaped —
catalog/cart/checkout/order/identity against one backend, no judgment calls.
System One is backend-agnostic the same way the agent loop is: it reasons
over typed value objects (`Product`, `Checkout`, an offer list) the Adapter/
client layer already produces, never over a specific platform's raw response
shape.

## Responsibilities

1. **Offer ranking / selection** — "which of these three products?" Partial
   precedent: `docs/design-log.md` §15's `portage find` pipeline already
   ranks multi-store offers (buyable stores first, then cheapest) but does it
   inline in the CLI command, not as a reusable typed decision another caller
   (an agent loop, a different frontend) can invoke on its own candidate list.
2. **Escalation policy** — "hand off vs. keep going." Partial precedent:
   `requires_escalation` branching is currently a *rule the agent is told to
   follow* (`skills/shop-via-ucp.md` guardrail 2) plus a CLI-side delivery
   mechanism once escalation has already been decided
   (`docs/plans/checkout-handoff-delivery.md`, `CheckoutHandoff`,
   `Notifier`). Nothing decides escalation from ambiguous signals (e.g. "did
   the merchant surface a mismatch that isn't literally `requires_escalation`
   but should still stop here?" — the kind of gap
   `82631bf Fix escalation reporting and surface checkout mismatches` just
   patched one instance of ad hoc).
3. **Confidence gating** — "only auto-proceed above threshold X." No
   precedent in this repo at all. `Confirmer` (`portage-ucp/lib/portage/ucp/
   confirmer.rb`) is binary — confirm or don't — not a graded confidence
   score a caller can threshold. This is the one responsibility above that's
   wholly new, not a consolidation of existing scattered logic.
4. **Simple policy checks** — budget, allowlist, risk signals.
   `Portage::Ucp::PolicyGuard` + `Policy` (`portage-ucp/lib/portage/ucp/
   policy_guard.rb`, `policy.rb`) already cover per-transaction cap, rolling
   cap, velocity, and merchant allowlist, wired into `Dispatcher`.
   `Decision::PolicyCheck` calls `PolicyGuard.check!` rather than
   reimplementing that, and adds risk signals as a caller-supplied
   `Hash{Symbol => Boolean}` gate alongside it (§ Open questions — the
   mechanism is built, the signals themselves are still uncomputed anywhere
   in this repo).

## Why a layer, not more Adapter methods or more CLI branches

- **Not Adapter-side**: a merchant backend has no opinion on whether *this
  buyer's agent* should auto-proceed — that's the buyer's own risk posture,
  not the store's. Pushing confidence/ranking/policy into `Adapter` subclasses
  would mean every adapter author re-implements the same judgment calls
  per-platform, the opposite of the Adapter contract's "protocol-only" design
  goal (`docs/design-log.md` §3).
- **Not CLI-side either**: `portage-cli`'s `Buy`/`CheckoutHandoff`/`Notifier`
  react to a decision already made (escalate, don't escalate) — they're
  delivery mechanisms, not the policy. Folding ranking/confidence/escalation
  logic into CLI command classes ties it to one frontend; an agent loop
  talking to `portage-ucp-client` directly (no CLI in the path) would get
  none of it.
- A typed decision layer between the two gives both the agent loop and any
  future frontend the same inspectable output: a ranked offer, an
  escalate/proceed verdict with a reason, a confidence score, a policy
  pass/fail — testable independent of any one transport or command.

## Open questions

- ~~Where does this live~~ **Resolved:** a new gem, `portage-ucp-decision`,
  alongside `portage-ucp-client` — `Portage::Ucp::Decision::*`, no unrelated
  branding inside the namespace.
- ~~Confidence gating needs a defined scale and source~~ **Resolved for the
  model-reported half:** `Decision::ModelBackends::Jev` (TypeSafe AI's hosted
  "System One Model" — the name this doc's title borrowed — `docs.typesafe.ai`,
  `POST https://api.typesafe.ai/v1/systemone`, `JEV_API_KEY` env var) and
  `Decision::ModelBackends::Laya` (`huggingface.co/convaiinnovations/laya`, an
  open-weights local model with no hosted API — this gem shells out to a
  Python bridge script, `LAYA_BRIDGE_SCRIPT` (`examples/laya_bridge.py` is a
  starting point), that speaks the same request/response JSON both backends
  share, plus `LAYA_INFER_COMMAND` as an escape hatch for a caller whose
  bridge isn't `python3 <script>`; a missing or broken bridge raises
  `BackendNotConfiguredError`/`BackendError` naming the exact problem — unset,
  path missing, `LAYA_PYTHON` not found, non-zero exit, invalid JSON). Both
  flow through `ConfidenceGate.via_backend`. `portage doctor` (aliased
  `configure`/`setup`) flags a missing `JEV_API_KEY` — not a missing Laya
  bridge, which stays opt-in and silent there since (unlike Jev) nothing
  expects every setup to configure it. The heuristic-over-signals half (price
  variance, stock volatility, merchant history) is still unevaluated.
- Relationship to `Confirmer` (`portage-ucp/lib/portage/ucp/confirmer.rb`):
  does confidence gating replace binary confirmation, sit in front of it
  (only ask for confirmation when confidence is low), or run independently?
  Unresolved.
- ~~Risk signals~~ **Mechanism resolved, computation still open:**
  `PolicyCheck#call`'s `risk_signals:` now denies on any truthy named
  signal (`{merchant_too_new: true}` → `reason: :risk_signal_triggered`).
  What a signal even is here — merchant age, TLS/manifest-signing status per
  §9, prior escalation rate — is still unresearched: nothing under
  `Portage::Ucp::Support` computes merchant trust/history, so producing an
  actual signal value stays the caller's job.
- ~~Ambiguous-signal escalation~~ **Resolved:** `EscalationPolicy#call`'s
  `signals:` now escalates on `mismatch: true` or a non-empty `warnings:`
  array — the same `warnings: [String]` vocabulary the not-yet-merged
  `82631bf Fix escalation reporting and surface checkout mismatches`
  (branch `feature/escalation-buyer-context-hardening`) puts on `Buy`'s
  report, so wiring that branch's `reconcile_checkout` output straight into
  `signals: {warnings:}` needs no translation once/if it merges.
