# portage-ucp-decision API

`portage-ucp-decision` (0.1.1) gives a shopping agent typed, inspectable purchase decisions: rank offers, decide whether to escalate, gate on a confidence score, and check spend policy.

Use it between your agent loop and the [client](portage-ucp-client.md). It depends on the core gem ([portage-ucp](portage-ucp.md)) and Faraday.

```ruby
require "portage/ucp/decision"
```

Every decision is a module function named `call` that returns a `Data` verdict. None of them raise for a normal "no".

## OfferRanking

Sorts candidate offers: buyable first, then priced, then cheapest. Ties keep input order.

| Item | Signature | Returns | Notes |
|---|---|---|---|
| `OfferRanking::Candidate` | `Data.define(:offer, :buyable, :amount)` | `Candidate` | `offer` is whatever you hold. `buyable` is true or false. `amount` is an Integer in minor units, or nil if unpriced. |
| `OfferRanking.call` | `OfferRanking.call(candidates)` | `Array<Candidate>` | The same candidates, ranked. Wraps `Portage::Ucp::Support::OfferRanking.rank`. |

```ruby
D = Portage::Ucp::Decision
ranked = D::OfferRanking.call([
  D::OfferRanking::Candidate.new(offer: "a", buyable: false, amount: 500),
  D::OfferRanking::Candidate.new(offer: "b", buyable: true,  amount: 900),
  D::OfferRanking::Candidate.new(offer: "c", buyable: true,  amount: 700)
])
ranked.map(&:offer) # => ["c", "b", "a"]
```

Source: `portage-ucp-decision/lib/portage/ucp/decision/offer_ranking.rb`, `portage-ucp/lib/portage/ucp/support/offer_ranking.rb`

## EscalationPolicy

Decides whether a purchase must stop and go to the shopper.

| Item | Signature | Returns | Notes |
|---|---|---|---|
| `EscalationPolicy.call` | `EscalationPolicy.call(checkout_status:, signals: {})` | `Verdict` | `signals[:warnings]` is an Array of mismatch strings. Any one escalates. |
| `EscalationPolicy::Verdict` | `Data.define(:escalate, :reason)` | | `escalate` is true or false. `reason` is `:requires_escalation`, `:mismatch` or nil. |

A `checkout_status` of `"requires_escalation"` wins over warnings.

```ruby
verdict = D::EscalationPolicy.call(checkout_status: checkout["status"],
                                   signals: { warnings: ["price changed"] })
verdict.escalate # => true
verdict.reason   # => :mismatch
```

Source: `portage-ucp-decision/lib/portage/ucp/decision/escalation_policy.rb`, `portage-ucp/lib/portage/ucp/support/escalation.rb`

## ConfidenceGate

Compares a confidence score to your own threshold. The gate has no default threshold.

| Method | Signature | Returns | Notes |
|---|---|---|---|
| `ConfidenceGate.call` | `ConfidenceGate.call(confidence:, threshold:)` | `Verdict` | Pure comparator. Use it with a score from your own heuristic. |
| `ConfidenceGate.via_backend` | `ConfidenceGate.via_backend(backend:, state:, question:, instructions:, threshold:)` | `Verdict` | Asks a backend one yes/no question and gates on the probability of yes. Phrase the question so "yes" means "safe to proceed". |

`ConfidenceGate::Verdict` is `Data.define(:proceed, :confidence, :threshold)`. `proceed` is `confidence >= threshold`.

`via_backend` asks a `"noul"` (yes/no) question only, on purpose. A choice's `confidence` measures how sure the model is of its answer, so a confident "escalate" would clear the threshold. To use a choice or score, call `backend#ask` yourself.

`via_backend` raises `BackendError` if the backend returns no answer under your `question` key, or the answer has no numeric value. It also raises whatever `backend.ask` raises.

```ruby
backend = D::ModelBackends.resolve(:jev)
verdict = D::ConfidenceGate.via_backend(
  backend: backend,
  state: checkout.to_json,
  question: "safe_to_buy",
  instructions: "Is it safe to complete this checkout without asking the shopper?",
  threshold: 0.9
)
verdict.proceed # => true or false
```

Source: `portage-ucp-decision/lib/portage/ucp/decision/confidence_gate.rb`

## PolicyCheck

Wraps core `PolicyGuard` (per-transaction cap, rolling cap, velocity, merchant allowlist, token scope) so a denial is a verdict, not an exception.

| Item | Signature | Returns | Notes |
|---|---|---|---|
| `PolicyCheck.call` | `PolicyCheck.call(amount:, currency:, merchant:, token_ref:, policy: Portage::Ucp::Policy.load, transaction_log: Portage::Ucp::Support::TransactionLog.new)` | `Verdict` | `amount` is an Integer in minor units, or nil (skips the two cap checks). |
| `PolicyCheck::Verdict` | `Data.define(:allowed, :reason)` | | `reason` is nil when allowed. Otherwise the `PolicyViolationError#reason` symbol. |

Reasons `PolicyGuard` can produce: `:per_transaction_cap_exceeded`, `:rolling_spend_cap_exceeded`, `:velocity_exceeded`, `:merchant_not_allowlisted`, `:token_scope_merchant`, `:token_scope_amount`, `:currency_mismatch`. Checks run in that broad order: spend cap, velocity, allowlist, token scope. The first failure wins.

The default `policy:` reads `~/.portage/policy.json`. A missing file or field means no restriction. A corrupt file raises a `JSON::ParserError` rather than allowing everything. The default `transaction_log:` uses the core log's default store.

```ruby
verdict = D::PolicyCheck.call(amount: 4_500, currency: "GBP", merchant: "shop.example", token_ref: nil)
verdict.allowed # => true
verdict.reason  # => nil
```

Source: `portage-ucp-decision/lib/portage/ucp/decision/policy_check.rb`, `portage-ucp/lib/portage/ucp/policy_guard.rb`, `portage-ucp/lib/portage/ucp/policy.rb`

## ModelBackends

Two swappable backends answer typed questions. Both implement `ask(state:, questions:)` and return `Hash{String => Answer}`.

| Item | Signature | Returns | Notes |
|---|---|---|---|
| `ModelBackends::REGISTRY` | `{ "jev" => Jev, "laya" => Laya }` | Hash | |
| `ModelBackends.resolve` | `ModelBackends.resolve(name, **opts)` | Backend instance | `name` is a String or Symbol. `opts` go to the backend constructor. Raises `UnknownBackendError` for an unknown name. |
| `ModelBackends::Question` | `Data.define(:type, :instructions, :criteria)` | | `criteria` defaults to nil. `type` is `"choice"` (criteria Hash), `"score"` (criteria Array) or `"noul"` (yes/no, no criteria). `#to_wire_h` builds the JSON body. |
| `ModelBackends::Answer` | `Data.define(:type, :confidence, :value)` | | `value` defaults to nil. It is the choice, the score, or a noul's probability of yes. |
| `ModelBackends.parse_answers` | `ModelBackends.parse_answers(raw, source:)` | `Hash{String => Answer}` | Parses `{"answers": {...}}`. Bad JSON or shape raises `BackendError`. |

### Jev

Hosted decision API from TypeSafe AI.

| Method | Signature | Returns | Notes |
|---|---|---|---|
| `new` | `Jev.new(api_key: Jev.env_api_key, model: "jev-latest", connection: nil)` | `Jev` | `connection` is a Faraday connection, for tests. Default timeouts: 5s open, 15s total. |
| `Jev.env_api_key` | `Jev.env_api_key` | `String`, `nil` | Reads `JEV_API_KEY`, then `TYPESAFE_API_KEY`. Blank values are skipped. |
| `configured?` | `configured?` | Boolean | True when `configuration_problem` is nil. |
| `configuration_problem` | `configuration_problem` | `String`, `nil` | Why it cannot answer yet, or nil. |
| `ask` | `ask(state:, questions:)` | `Hash{String => Answer}` | `state` is a String. `questions` is `Hash{String => Question}`. |

### Laya

Local open-weights model, reached through a bridge command you provide. It shells out and speaks JSON on stdin/stdout: `{"state", "questions"}` in, `{"answers"}` out. A starting bridge is at `portage-ucp-decision/examples/laya_bridge.py`.

| Method | Signature | Returns | Notes |
|---|---|---|---|
| `new` | `Laya.new(bridge_script: ENV["LAYA_BRIDGE_SCRIPT"], python: ENV["LAYA_PYTHON"] \|\| "python3", command: ENV["LAYA_INFER_COMMAND"], timeout: 60)` | `Laya` | `command:` overrides `bridge_script:` and `python:`. |
| `configured?` | `configured?` | Boolean | |
| `configuration_problem` | `configuration_problem` | `String`, `nil` | Checks the script exists and Python is executable, unless `command:` is set. |
| `ask` | `ask(state:, questions:)` | `Hash{String => Answer}` | Kills the bridge on timeout. |

### Backend errors

All inherit from `Portage::Ucp::Decision::Error < StandardError`.

| Class | Raised when |
|---|---|
| `BackendNotConfiguredError` | `ask` is called and `configuration_problem` is set (no API key, no bridge). |
| `BackendError` | Non-2xx from Jev, a Faraday error, a non-zero Laya exit, a Laya timeout, a bridge that cannot start, or an unreadable reply. |
| `UnknownBackendError` | `ModelBackends.resolve` gets a name not in `REGISTRY`. |

Source: `portage-ucp-decision/lib/portage/ucp/decision/model_backends.rb`, `portage-ucp-decision/lib/portage/ucp/decision/model_backends/answer.rb`, `portage-ucp-decision/lib/portage/ucp/decision/model_backends/jev.rb`, `portage-ucp-decision/lib/portage/ucp/decision/model_backends/laya.rb`, `portage-ucp-decision/lib/portage/ucp/decision/errors.rb`

## End to end

```ruby
require "portage/ucp/decision"
D = Portage::Ucp::Decision

offers = [
  D::OfferRanking::Candidate.new(offer: { shop: "a.example", id: "p1" }, buyable: true, amount: 4_500),
  D::OfferRanking::Candidate.new(offer: { shop: "b.example", id: "p9" }, buyable: true, amount: 3_900)
]
best = D::OfferRanking.call(offers).first

# ... build a checkout for best.offer with the client, then:
escalation = D::EscalationPolicy.call(checkout_status: checkout["status"], signals: { warnings: [] })
return hand_to_shopper(checkout) if escalation.escalate

policy = D::PolicyCheck.call(amount: best.amount, currency: "GBP", merchant: best.offer[:shop], token_ref: nil)
return warn("blocked: #{policy.reason}") unless policy.allowed

gate = D::ConfidenceGate.call(confidence: my_score, threshold: 0.9)
proceed = gate.proceed # complete_checkout only if true
```

For the client calls, see [portage-ucp-client](portage-ucp-client.md).
