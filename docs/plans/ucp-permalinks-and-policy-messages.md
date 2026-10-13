# UCP 2026-08-25: Shopping Permalinks and Policy Messages

**Status:** Phases 1 to 3 done. Follows [ucp-2026-08-25.md](ucp-2026-08-25.md) and design-log §60 (`policies[]`).

**Goal:** advertise the `dev.ucp.shopping.permalink` capability, and emit the `messages[]` warnings that carry a buyer-facing obligation to show a policy.

## What the spec says

**Permalinks** (`schemas/shopping/permalink.json`, `services/shopping/permalink.openapi.json`). A capability for a browser endpoint the *business* serves: `GET {endpoint}/{item_id:qty,...}?<field-path>=<value>&continue_to=/path` resolves a shopping intent and answers `303` (never 301/308) with `Cache-Control: no-store` and `Referrer-Policy: no-referrer`. It defines no fields of its own; query parameters address existing UCP field paths. The business profile entry requires `config.endpoint`: absolute https, no userinfo, query, fragment or trailing slash. Platforms declare it with no config. `order.permalink_url` and `order_confirmation.permalink_url` are a different thing (an order page link) and already exist.

**Policy messages** (`common/types/policy.json`, message types). A buyer-facing obligation to show a policy is a `messages[]` warning whose `code` equals the policy `type`.

## Phases

**Phase 1: permalinks.** `Adapter#permalink_endpoint` (nil by default) advertises the capability with `config.endpoint`. No MCP tool: the spec defines only a browser redirect, not a UCP operation.

**Phase 2: policy messages.** Where `policies[]` is present on checkout (and cart if its schema allows `messages[]`), add a warning per policy with `code` = policy `type`, per spec semantics (path, severity, content fields).

**Phase 3: adapter messages, shared `html_to_text`.** `Cart` and `Checkout` take a stored `messages:` array of wire-shaped hashes so adapters can add their own; `to_wire_h` emits them first, then the derived policy warnings, skipping a derived warning when the adapter already supplied a warning with the same `code`. Rebuilds carry only the stored adapter messages. `portage-ucp-shopify` drops its private `html_to_text` for `Portage::Ucp.html_to_text`; the `portage-ucp ~> 0.16` floor waits for the release commit.

## Out of scope

Serving the permalink redirect route (the host app's job), parsing permalink query parameters, and adapter-side endpoints beyond what an adapter already knows.

## Progress log

| Date | Phase | Result | Commit |
|---|---|---|---|
| 2026-10-13 | 1 | `Capability#config_for`, `Capabilities::PERMALINK`, `Adapter#permalink_endpoint`; manifest emits `config.endpoint` and validates against `business_schema`. No adapter supplies an endpoint. Design-log §61. | see git log |
| 2026-10-13 | 2 | `Portage::Ucp.policy_messages`; `Cart` and `Checkout` derive a `disclosure` warning per policy in `to_wire_h`. Orders left out (post-purchase snapshot). Design-log §62. | see git log |
| 2026-10-13 | 3 | `messages:` on `Cart` and `Checkout`, merged ahead of derived warnings with same-code suppression; Shopify uses `Portage::Ucp.html_to_text`, dependency bump deferred to its release commit. Design-log §63. | see git log |
