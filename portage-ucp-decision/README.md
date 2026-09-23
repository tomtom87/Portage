# portage-ucp-decision

The System One decision layer for `portage-ucp` — see
`docs/plans/system-one-decision-layer.md` for why this exists.

Sits between the agent loop and the Adapter/client layer, turning judgment
calls that were scattered across skill instructions, `portage-cli`, and
`portage-ucp` into typed, inspectable decisions:

- `Portage::Ucp::Decision::OfferRanking` — which offer to pick among several.
  A typed wrapper around `Portage::Ucp::Support::OfferRanking`.
- `Portage::Ucp::Decision::EscalationPolicy` — hand off vs. keep going. A
  typed wrapper around `Portage::Ucp::Support::Escalation`.
- `Portage::Ucp::Decision::ConfidenceGate` — proceed unattended above a
  threshold.
- `Portage::Ucp::Decision::PolicyCheck` — a typed wrapper around
  `Portage::Ucp::PolicyGuard.check!`.

The ranking, escalation and policy rules live in `portage-ucp` core, and
these three wrap them as `Verdict`s. `portage-cli` calls the core modules
directly, so it answers the same way with or without this gem. Only
`ConfidenceGate` and its model backends are unique to this gem.

`ModelBackends::Laya` needs a Python bridge script (it's HuggingFace weights,
not a hosted API) — see `examples/laya_bridge.py` and set
`LAYA_BRIDGE_SCRIPT`; a missing or broken bridge raises
`BackendNotConfiguredError`/`BackendError` with a message naming the exact
problem (unset, path doesn't exist, `LAYA_PYTHON` not executable, non-zero
exit, timeout, unreadable reply). The bridge must answer with the same
`{"answers": {name => answer}}` body Jev returns, each answer keyed by its
type: `{"type": "noul", "noul": <P(yes)>}`, `{"type": "choice", "choice":
<option>, "confidence": <c>}`, `{"type": "score", "score": <level>,
"confidence": <c>}`. `ModelBackends::Jev` reads `JEV_API_KEY` (falling back
to `TYPESAFE_API_KEY`, TypeSafe's own name for it).

Both backends time out (Jev after 5s to connect and 15s to answer, Laya
after 60s by default, `timeout:`), and every failure — a timeout, a
connection error, a reply that isn't that shape — raises a
`Decision::Error` subclass, so one `rescue Portage::Ucp::Decision::Error`
covers a backend call. `#configuration_problem` returns the reason a backend
can't answer yet (nil when it can); `portage doctor` reports it for the
backend `PORTAGE_DECISION_BACKEND` selects, and says nothing when none is
selected.

`EscalationPolicy` branches on the literal `requires_escalation` status plus
an ambiguous-signal case (`signals: {warnings:}`, any warning escalates).
`ConfidenceGate` compares a score it's handed (`.call`) or gets one from a
model backend (`.via_backend`, `ModelBackends::Jev`/`ModelBackends::Laya`).
See the plan doc's "Open questions" section for what's still unresolved.

## Usage

```ruby
require "portage/ucp/decision"

Portage::Ucp::Decision::EscalationPolicy.call(checkout_status: checkout.status)
# => #<data Verdict escalate=true, reason=:requires_escalation>
```

`ConfidenceGate.via_backend` asks one yes/no ("noul") question and gates on
the probability the backend answered yes, so phrase the question so "yes"
means "safe to proceed":

```ruby
jev = Portage::Ucp::Decision::ModelBackends::Jev.new

Portage::Ucp::Decision::ConfidenceGate.via_backend(
  backend: jev, state: checkout.to_json, question: "safe_to_complete", threshold: 0.8,
  instructions: "Answer yes only if this checkout is safe to complete without a person reviewing it."
)
# => #<data Verdict proceed=false, confidence=0.37, threshold=0.8>
```

## What this gem leaves out, and why

These were in the first skeleton and were removed before 0.1.0 was
published, because nothing called them:

- **Choice and score questions in `ConfidenceGate`** (`type:`, `criteria:`,
  `proceed_on:`). A choice's or score's `confidence` says how sure the model
  is of whichever answer it gave, so a confident "escalate" clears the
  threshold; `proceed_on:` was needed just to stop that. A noul's
  yes-probability is the one number that means "safe to proceed", and it's
  the only question `portage buy` asks. To use a choice or score, call the
  backend's `#ask` yourself and read the `Answer`.
- **`ModelBackends::Answer#probabilities`.** Parsed from the reply but read
  by nothing.
- **`EscalationPolicy`'s `mismatch:` signal.** `warnings:` covers it: pass
  a one-line description of the mismatch.
- **`EscalationPolicy::ESCALATING_STATUSES`.** It only ever held
  `requires_escalation`, which is `Portage::Ucp::Support::Escalation::STATUS`.
- **`PolicyCheck`'s `risk_signals:`, and the `decision:` field on its
  `Verdict`.** Nothing computes a risk signal yet (merchant age,
  TLS/manifest signing, escalation rate), and `decision:` repeated
  `allowed`/`reason`. A caller with its own signal can deny before calling
  `PolicyCheck`.

## Development

```
bundle install
bundle exec rspec
bundle exec rubocop
```
