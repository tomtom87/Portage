# Buying over raw UCP/MCP (no `portage` CLI)

Use this only when `portage` can't be installed. The CLI enforces all of this in code. Here you have to enforce it yourself.

## Guardrails

1. **Discover before assuming anything.** `GET <store>/.well-known/ucp` first. If it's missing, or doesn't advertise checkout, say automated purchase isn't available there. Don't scrape, don't log in as the user, and don't use anyone's stored credentials.
2. **`requires_escalation` is data, not an error.** Give the user the `links` / `continue_url` and stop. Don't retry.
3. **Never send a raw card number as `payment_token`.** Reject any string that's all digits, 12-19 characters and Luhn-valid.
4. **Hand-off-only hosts (Amazon, etc.) are never called at all.** See [handoff-only.md](handoff-only.md).
5. **Never pay for a checkout that doesn't match what the user approved.** Before `complete_checkout`, check the checkout's items, quantities, unit prices, currency and total against what the user said yes to. On any difference, stop: don't complete it and don't hand it off as if it matched. Show the user what differs, and build a fresh checkout for a new yes. The CLI does the same (`checkout_mismatch`).

## Sequence

1. `GET <store>/.well-known/ucp`. Read `capabilities` and `services`. The service with `"transport": "mcp"` has the endpoint.
2. Every call carries `meta.agent_profile` (a URL describing this agent). The profile must declare `dev.ucp.shopping.catalog.search` and `dev.ucp.shopping.catalog.lookup`. The coarse `dev.ucp.shopping.catalog` gets you `Tool not found`.
3. Every catalog, cart and checkout call carries a `context`: `address_country`, plus `currency`, `address_region`, `postal_code` and `language` when known. Without it, carts come back empty with `merchandise_out_of_stock`.
4. `tools/call search_catalog { "query": "...", "limit": 5 }`. Show the user the matches.
5. `tools/call get_product { "product_id": "..." }` for variant detail.
6. `tools/call create_checkout { "line_items": [...], "idempotency_key": "<new>" }`. Check it against the request (guardrail 5), then show the user the total and get an explicit yes.
7. If you hold a tokenized credential and the store allows agent completion: `tools/call complete_checkout { "checkout_id": "...", "payment_token": "...", "idempotency_key": "<new>" }`. Otherwise give the user `continue_url`. That's the normal path for most stores (Shopify gates `complete_checkout` per merchant).
8. `tools/call get_order { "order_id": "..." }` to report fulfilment and tracking.
