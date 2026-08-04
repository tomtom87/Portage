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
