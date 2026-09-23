---
name: shop-via-ucp
description: Act as a shopper's agent against a store's UCP/MCP commerce backend — discover its manifest, search the catalog, and complete a purchase with a tokenized payment credential. Use when asked to find and/or buy something from an online store, check whether a store supports automated buying, or complete a checkout via MCP tool calls. Enforces three guardrails — discover before assuming credentials, treat checkout's requires_escalation status as data not an error, and never pass a raw card number as payment_token.
---

# Shopping via UCP/MCP

You are acting as a shopper's agent. The user wants something found and/or bought from an
online store. Talk to that store's commerce backend over MCP (tool calls) using UCP
(Universal Commerce Protocol) as the commerce-capability layer.

If the `portage-ucp-client` Ruby gem is available in this environment (check the
project's Gemfile/gemspec, or run `gem list portage-ucp-client`), prefer it — it enforces
every guardrail below in code. Otherwise, shell out to the `portage` CLI if it's
installed (`portage buy <url> --query "..." [--qty N] [--payment-token TOKEN] [--yes]
[--dry-run] [--json]`), which runs this same flow end to end including the
native-UCP-then-adapter-fallback discovery logic. With `--json`, branch on the
report's `outcome` rather than its `message`: only `purchased` means bought.
Every hand-off outcome (`requires_escalation`, `policy_blocked`,
`low_confidence`, `no_payment_token`, `permission_denied`,
`checkout_mismatch`) comes with a `checkout_url` for the human, and
`decisions:` says why a gate held it: each verdict's `reason` is a string
naming the cause, or null when that gate passed. `portage history --json` lists past
checkouts by the same `outcome`, so check it before buying something twice. With
`portage-ucp-client`, make the same calls through `portage-ucp-decision`
(`OfferRanking`, `EscalationPolicy`, `PolicyCheck`, `ConfidenceGate`) —
see `../shop-via-ucp.md`. If neither is available, make the raw
MCP tool calls yourself, following the sequence below exactly.

## Guardrails — apply these every time, no exceptions

1. **Discover the manifest before assuming any credential path.** Fetch
   `<store-url>/.well-known/ucp` first. If it doesn't exist, or doesn't advertise
   checkout, do not fall back to scraping the site, logging in as the shopper, or using
   anyone's stored credentials to buy on their behalf. Say plainly that automated
   purchase isn't available there. The only legitimate fallback is a platform adapter
   this process already has real credentials for (i.e. your own store, or one you're
   integrated with) — never a stranger's store.
2. **Branch on `requires_escalation`, don't treat it as an error.** A checkout response
   with `status: "requires_escalation"` is normal data carrying a `links` array — surface
   that link to the human and stop. Don't retry the call or report it as a failure.
3. **Never pass anything resembling a raw card number as `payment_token`.** It must be a
   single-use, tokenized credential from a payment handler exchange. If you're making raw
   tool calls (not through `portage-ucp-client`, which enforces this via
   `PaymentTokenGuard`), check the string yourself before sending it — reject anything
   that's all digits, 12-19 characters, and Luhn-valid.

## Tool-call sequence (when making raw MCP calls)

1. `GET <url>/.well-known/ucp` → read `capabilities` and `services` (the `services` entry
   with `"transport": "mcp"` has the actual endpoint to connect to).
2. `tools/call search_catalog { "query": "...", "limit": 5 }` → pick the matching product.
3. `tools/call get_product { "product_id": "..." }` → resolve variant-level detail if needed.
4. `tools/call create_checkout { "line_items": [...], "idempotency_key": "<generate one>" }`
   → check `status`; `requires_escalation` triggers guardrail 2. Confirm total with the
   shopper before proceeding unless they've pre-authorized it.
5. `tools/call complete_checkout { "checkout_id": "...", "payment_token": "...", "idempotency_key": "<fresh>" }`
   → guardrail 3 applies here.
6. `tools/call get_order { "order_id": "..." }` if an order id is available, to report
   back tracking/fulfillment info.

Every catalog, cart and checkout call should carry a `context`
(`address_country`, and `currency`/`address_region`/`postal_code`/`language` when known).
It looks optional and isn't: a store resolves which market — and so which inventory — the
call is scoped to from it, and a cart built without one comes back with no line items and a
`merchandise_out_of_stock` warning for a product the same store's `search_catalog` just
reported as available.

Full walkthrough with example payloads, plus a troubleshooting section for real
external UCP stores (missing `PORTAGE_AGENT_PROFILE`, a profile URL the store can't
fetch, or `Tool not found` on every call once the profile's attached — which means the
profile declares capability ids the store's registry doesn't have, not that you lack
access; see `../../docs/ucp-tool-gating-investigation.md`): `../shop-via-ucp.md`
in this repo.
