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
  `Portage::Ucp::PolicyGuard.check!`.

This is a first skeleton, not a finished layer. `EscalationPolicy` only
branches on the literal `requires_escalation` status; `ConfidenceGate` only
compares a score it's handed, it doesn't produce one; `PolicyCheck`'s
`risk_signals:` is accepted but not yet checked. See the plan doc's "Open
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
