# portage-ucp-decision

The System One decision layer for `portage-ucp` — see
`docs/plans/system-one-decision-layer.md` for why this exists.

Sits between the agent loop and the Adapter/client layer, turning judgment
calls that were scattered across skill instructions, `portage-cli`, and
`portage-ucp` into typed, inspectable decisions:

- `Portage::Ucp::Decision::OfferRanking` — which offer to pick among several.
- `Portage::Ucp::Decision::EscalationPolicy` — hand off vs. keep going.
- `Portage::Ucp::Decision::ConfidenceGate` — proceed unattended above a
  threshold.
- `Portage::Ucp::Decision::PolicyCheck` — a typed wrapper around
  `Portage::Ucp::PolicyGuard.check!`, plus a `risk_signals:` gate.

`ModelBackends::Laya` needs a Python bridge script (it's HuggingFace weights,
not a hosted API) — see `examples/laya_bridge.py` and set
`LAYA_BRIDGE_SCRIPT`; a missing or broken bridge raises
`BackendNotConfiguredError`/`BackendError` with a message naming the exact
problem (unset, path doesn't exist, `LAYA_PYTHON` not on PATH, non-zero exit,
invalid JSON). `ModelBackends::Jev` reads `JEV_API_KEY`, and — since it's the
one with no opt-in step, just a key — a missing one is also flagged by
`portage doctor`/`portage configure`/`portage setup`. Laya stays optional and
silent in `doctor` on purpose: unlike Jev it has no default "everyone needs
this" expectation, so an unconfigured bridge isn't a doctor finding.

`EscalationPolicy` branches on the literal `requires_escalation` status plus
an ambiguous-signal case (`signals: {warnings:, mismatch:}`). `ConfidenceGate`
compares a score it's handed (`.call`) or gets one from a model backend
(`.via_backend`, `ModelBackends::Jev`/`ModelBackends::Laya`). `PolicyCheck`'s
`risk_signals:` denies on any truthy named signal — the mechanism is real,
but nothing in this repo computes an actual merchant-age/TLS/escalation-rate
signal yet, so that's still the caller's job. See the plan doc's "Open
questions" section for what's still unresolved.

## Usage

```ruby
require "portage/ucp/decision"

Portage::Ucp::Decision::EscalationPolicy.call(checkout_status: checkout.status)
# => #<data Verdict escalate=true, reason=:requires_escalation>
```

## Development

```
bundle install
bundle exec rspec
bundle exec rubocop
```
