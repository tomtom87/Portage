# Shopping via UCP/MCP

Use this when you're acting as a shopper's agent — the user has asked you to find and/or
buy something from a store, and you need to talk to that store's commerce backend over
MCP (the tool-call protocol) using UCP (Universal Commerce Protocol, the commerce
capability layer on top of MCP). This is harness-agnostic: it describes the tool-call
sequence and the guardrails, not any one framework's syntax. If you have the
`portage-ucp-client` Ruby gem available, its `Portage::Ucp::Client` does all of this for
you (see "Using portage-ucp-client" at the end); otherwise, make the raw MCP tool calls
described below.

## The three guardrails (non-negotiable)

1. **Discover the manifest before assuming any credential path.** Every store you're
   asked to buy from should be reached by first fetching `<store-url>/.well-known/ucp`
   and reading what it advertises (`capabilities`, `services`). Never assume a store
   supports UCP, and never fall back to logging in as the shopper, scraping the site, or
   using anyone's stored credentials to complete a purchase on their behalf — if the
   store hasn't opted into UCP and you have no legitimate credentials of your own for it
   (e.g. it's not your own store), the honest answer is "I can't buy this automatically,"
   not "let me find another way in."
2. **Branch on `requires_escalation`, don't treat it as an error.** A checkout's `status`
   can come back `requires_escalation` — this is normal data, not a failure. It means the
   buyer needs to complete something outside this tool-call flow (identity verification,
   a policy acknowledgment, whatever). The response includes `links` with a URL — surface
   that link to the human and stop; don't retry, don't treat it as a bug.
3. **Never pass anything that looks like a raw card number as `payment_token`.**
   `complete_checkout`'s `payment_token` must be a single-use, tokenized credential from a
   payment handler / AP2 exchange — never a PAN (the 12-19 digit number on a physical
   card). If you're making raw MCP tool calls yourself (not through `portage-ucp-client`,
   which enforces this in code via `PaymentTokenGuard`), you are the only guard standing
   between a card number and the wire — check the string yourself before sending it.

## The tool-call sequence

Given a store URL and something to buy:

**1. Discover.** `GET <url>/.well-known/ucp`. Read `capabilities` (does it advertise
`dev.ucp.shopping.catalog`/`cart`/`checkout`?) and `services` (where's the actual MCP
endpoint — `services` entries look like `{"transport": "mcp", "endpoint": "https://..."}`).
No manifest, or no checkout capability advertised → you can still browse if catalog is
there, but say plainly that you can't complete a purchase this way.

**2. Search the catalog.**

```
tools/call search_catalog { "query": "snowboard", "limit": 5 }
```

Returns a list of products (id, title, price, availability). Pick the one that matches
what the shopper asked for.

**3. Get full product detail**, if you need variant-level info (size, color) to choose
the right line item.

```
tools/call get_product { "product_id": "<id from step 2>" }
```

**4. Create a checkout** for the chosen line item(s). Generate an `idempotency_key`
yourself (any unique string) — if this call gets retried (dropped connection, you call it
twice by mistake), the server returns the same result instead of double-charging.

```
tools/call create_checkout {
  "line_items": [{ "product_id": "<variant id>", "quantity": 1 }],
  "idempotency_key": "<your generated key>"
}
```

Check the response's `status`. `requires_escalation` → guardrail 2, stop and surface the
link. Otherwise you get a checkout with totals — this is the moment to confirm with the
human shopper before spending real money, unless they've already told you to proceed
without asking.

**5. Complete checkout** with a tokenized payment credential — never a raw card number
(guardrail 3). Where that token comes from depends on the shopper's payment handler; you
don't invent one.

```
tools/call complete_checkout {
  "checkout_id": "<id from step 4>",
  "payment_token": "<opaque token, never a PAN>",
  "idempotency_key": "<same key style as step 4, generate fresh for this call>"
}
```

**6. Fetch the resulting order**, if you have an order id to look up (not every store
gives you one directly from checkout completion — some link cart→order asynchronously).

```
tools/call get_order { "order_id": "<id, if known>" }
```

Report back what was bought, the total charged, and any order/tracking reference you got.

## Using portage-ucp-client

If you're running in a Ruby environment with `portage-ucp-client` available, use it
instead of raw tool calls — it implements all three guardrails in code, generates
idempotency keys for you, and gives you one interface regardless of whether the store is
native UCP, a subprocess (stdio), or an HTTP endpoint:

```ruby
require "portage/ucp/client"

session = Portage::Ucp::Client.discover("https://the-store.example")
# raises Portage::Ucp::Client::DiscoveryError if there's no manifest / no mcp service —
# that's your signal to say "I can't buy this automatically here."

products = session.search_catalog(query: "snowboard", limit: 5)
checkout = session.create_checkout(line_items: [{ product_id: products.first["id"], quantity: 1 }])
# checkout["status"] == "requires_escalation" -> surface checkout["links"], stop here.

completed = session.complete_checkout(checkout_id: checkout["id"], payment_token: token)
# PaymentTokenGuard runs automatically inside complete_checkout — a raw PAN raises
# Portage::Ucp::RawPanRejectedError before anything goes on the wire.
```

For your own store (you already have Adapter credentials, no manifest to discover):

```ruby
session = Portage::Ucp::Client.for_adapter(my_adapter)
```

## Making the judgment calls with portage-ucp-decision

Picking an offer, deciding to hand off, and deciding whether a spend is
allowed are decisions, not steps in the tool-call sequence. If
`portage-ucp-decision` is available, make them through it rather than by
eye. Each call returns a typed verdict you can log and branch on:

```ruby
require "portage/ucp/decision"
D = Portage::Ucp::Decision

# Which offer? Buyable first, then cheapest, then unpriced.
ranked = D::OfferRanking.call(offers.map { |o| D::OfferRanking::Candidate.new(offer: o, buyable: o[:checkout], amount: o[:amount]) })

# Hand off or keep going? Guardrail 2, as code. Pass any mismatch you
# noticed between the checkout and the request as warnings.
verdict = D::EscalationPolicy.call(checkout_status: checkout["status"], signals: { warnings: warnings })
# verdict.escalate -> surface the checkout's continue_url to the human and stop.

# Is this spend allowed by the shopper's own policy? Run it before
# complete_checkout. A remote store's server never sees the shopper's policy.
policy = D::PolicyCheck.call(amount: total, currency: checkout["currency"], merchant: store_host,
                             token_ref: Portage::Ucp::Support::TokenRef.for(token))
# policy.allowed == false -> don't complete; tell the human policy.reason.
```

Without `portage-ucp-decision`, the same three rules are in `portage-ucp`
core, untyped: `Portage::Ucp::Support::OfferRanking.rank(offers) { |o|
[o[:checkout], o[:amount]] }`, `Portage::Ucp::Support::Escalation.reason(
checkout_status:, warnings:)`, and `Portage::Ucp::PolicyGuard.check!`
(raises `PolicyViolationError` with a `reason`).

Before completing a purchase without asking the human, you can also gate on
a model's confidence (`D::ConfidenceGate.via_backend`, with
`D::ModelBackends::Jev` or `Laya`). Treat a low score or a backend error as
"ask the human", never as "proceed".

If you shell out to `portage buy --json` instead, it makes these same calls
for you. Branch on the report's `outcome`, not on the `message` text:
`purchased` is the only outcome that bought anything. `needs_confirmation`
and `dry_run` stopped before completing on purpose. The hand-off outcomes
(`requires_escalation`, `policy_blocked`, `low_confidence`,
`no_payment_token`, `permission_denied`, `checkout_mismatch`) each come
with a `checkout_url` to hand the human. The gate verdicts behind them are
under `decisions:`. Each verdict has a `reason`, null when that gate passed:
`escalation.reason` (`requires_escalation`, `mismatch`), `policy.reason`
(`per_transaction_cap_exceeded`, `merchant_not_allowlisted`, ...), and
`confidence.reason` (`below_threshold`, `backend_error`, `not_installed`,
with the detail in `confidence.error`). Don't infer
success from `decisions:` alone: a missing payment token or a
permission-denied store holds a purchase without any gate saying no.
`items:` is what the checkout holds, and `products:` is only the search
results. The full list of outcomes is in `portage-cli`'s README.

## Troubleshooting a real, external UCP store

Confirmed live against billabong.com's native Shopify UCP endpoint
(2026-09-17). Errors here look like transport failures but are usually
setup, not a bug in your call:

- **"Set PORTAGE_AGENT_PROFILE..."** — every HTTP-transport call (i.e.
  anything through `discover`, not `for_adapter`) must carry
  `meta: { agent_profile: <url> }`, and the store fetches that URL itself
  before answering. Set the env var and pass it through explicitly —
  `session.search_catalog(..., meta: { agent_profile: ENV.fetch("PORTAGE_AGENT_PROFILE") })`.
  `portage-cli`'s own commands do this for you; raw `Session` calls don't.
- **A 422 "the request is unprocessable" with an empty response body**,
  right after wiring up `PORTAGE_AGENT_PROFILE`, usually means the profile
  URL itself failed the store's fetch — most often a `Content-Type` that
  isn't `application/json`. `raw.githubusercontent.com` serves `.json`
  files as `text/plain` and fails this silently (no error detail comes back
  over the wire). Check with `curl -I <profile-url>` — you want `HTTPS`, no
  `3xx` redirect, `Content-Type: application/json`, and a public
  `Cache-Control: max-age=60` or higher. `cdn.jsdelivr.net/gh/<owner>/<repo>@<ref>/<path>`
  is a reliable way to serve a file straight out of a GitHub repo with the
  right headers, with no Pages deploy required.
- **`-32602 Invalid params, "Tool not found: <name>"` for every tool**, even
  ones `tools/list` just confirmed exist, once the profile is wired up and
  fetchable — the tool isn't actually missing, and this is your profile, not
  the store's permissions. A server resolves an agent's tool registry from
  the capability ids the profile declares, and a declared id that isn't in
  the registry resolves to no tools at all, reported as a lookup miss. The
  trap is catalog: it is registered per action —
  `dev.ucp.shopping.catalog.search` and `dev.ucp.shopping.catalog.lookup` —
  so a profile declaring a coarse `dev.ucp.shopping.catalog` gets zero
  catalog tools. Cart, checkout and order are declared at the root name.
  Versions are spec revisions (`2026-08-25`), not `"1"`, and `ucp.services`
  must declare the shopping service rather than being left `{}`. This repo
  got all three wrong for a month and misread the result as a platform
  allowlist; `docs/ucp-tool-gating-investigation.md` has the full trail.
- **A cart that comes back empty and calls itself sold out** — `create_cart`
  returns `status: "success"` with `line_items: []`, zeroed totals, and a
  `merchandise_out_of_stock` warning naming a product `search_catalog`
  reported as `availability.available == true` seconds earlier. You didn't
  send a `context`. A store resolves which market — and so which
  publication and which inventory — the call is scoped to from it, and
  without one the call is scoped to no market and every line silently
  drops. Send `address_country` at minimum, plus
  `currency`/`address_region`/`postal_code`/`language` when you know them,
  on catalog, cart and checkout calls alike. Don't report this to the
  shopper as "out of stock" — it isn't.

  Sending a context is necessary but **not sufficient**, so the same symptom
  can survive it: the cart is scoped to whatever market your context names,
  and if the store doesn't publish that product into that market the lines
  drop again with the identical message. Confirmed across nine third-party
  Shopify stores, 2026-09-22 — on mejuri.com, `create_cart` with a `US`/`USD`
  or `GB`/`GBP` context came back empty and "already sold out", while the
  same variant with `CA`/`CAD` carried fine. Worse, `search_catalog` on that
  store ignored the context outright: it answered every market with the same
  CAD prices and `availability.available == true`, so nothing in the search
  result hinted the product was unreachable from the context being used. So
  treat the search result's `availability` as advisory, and read
  `merchandise_out_of_stock` on a just-searched item as "wrong market,
  probably" first and genuine stock second — try the store's home market
  (the currency its catalog quotes in) before telling the shopper anything.

  Omitting the context does not always empty the cart, either — the other two
  outcomes are worse to debug because the response looks fine. Of the nine
  stores, three built a correct cart with no context at all, one emptied it,
  and five silently priced it in the market of the *caller's IP address*
  (a run from Bangkok got THB carts from `kith.com`, `glossier.com`,
  `chubbiesshorts.com`, `mejuri.com` and `thelightyard.co.uk`). A cart whose
  total is in a currency the shopper never mentioned is a valid-shaped wrong
  answer, and no message on the response says so.
- **`"You are forbidden to make tools/call requests"` on `get_order`, or a
  refusal on `complete_checkout`** — these two are real permission
  boundaries, not the registry miss above. Orders needs a Dev Dashboard
  token carrying `read_global_api_orders`. `complete_checkout` needs both
  checkout permission on the token and the merchant having your agent's
  channel enabled, granted case by case. Catalog, cart and checkout
  build/edit tools need none of that. For completion without that grant,
  hand the shopper the `continue_url` carried on every cart and checkout
  response and let them finish in the merchant's own checkout — that is the
  supported path, not a workaround.
- For any of these: don't retry the call, don't fall back to scraping or
  raw credentials, and don't report it to the shopper as "the store is
  down." Say plainly that this store's automated-buying setup isn't working
  yet and, if you can, name which of the above it looks like.
