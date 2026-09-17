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
  fetchable — the tool isn't actually missing. Confirmed root cause: a
  platform-side gate on tool *invocation* that Shopify's real UCP rollout
  applies independent of the agent-profile document's validity/content and
  independent of who runs the store (reproduces identically against
  billabong.com and a self-owned Shopify dev store). The proof is
  `get_order`, which returns an honest `"You are forbidden to make
  tools/call requests"` for the same session regardless of whether the
  profile URL is real or garbage — `search_catalog`/`create_cart`/etc. hit
  the same gate but surface it as this misleading "Tool not found" instead,
  because the tool is silently missing from this agent's per-session
  registry. There is no client-side fix: treat this as "this store hasn't
  opened automated buying to this agent" and say so, rather than assuming
  it's your profile content or your call shape. Whether Shopify publishes an
  allowlist/approval process, and whether this is Shopify-specific or
  protocol-wide, is still open — see `docs/ucp-tool-gating-investigation.md`
  in this repo for the full investigation and open next steps.
- In all three cases: don't retry the call, don't fall back to scraping or
  raw credentials, and don't report it to the shopper as "the store is
  down." Say plainly that this store's automated-buying setup isn't working
  yet and, if you can, name which of the three above it looks like.
