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
native-UCP-then-adapter-fallback discovery logic. If neither is available, make the raw
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

Full walkthrough with example payloads: `../shop-via-ucp.md` in this repo (same content,
framework-neutral prose — read it if you want the fully worked example).
