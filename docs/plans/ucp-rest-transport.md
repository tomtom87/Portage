# UCP REST Transport in the Client

**Status:** Planned (2026-11-18). Nothing built yet.

**Driver:** [issue #178](https://github.com/tomtom87/Portage/issues/178). A third-party UCP 2026-08-25 sandbox advertises only a `rest` service, and `Portage::Ucp::Client.discover` fails with `ManifestShapeError: manifest has no mcp service entry to connect to` ([client.rb:111](../../portage-ucp-client/lib/portage/ucp/client.rb#L111)). The 2026-08-25 overview calls REST the **core** transport and MCP one option among several, so a REST-only store is valid and Portage can't buy from it.

## Goal

A REST-only store works everywhere a MCP store works today: `portage buy`, `find`, `check`, the index builder, the handoff reconciler, payment methods, browser import, and the buyer MCP server. Nobody calling `Session` should be able to tell which transport is underneath.

## Why this is small

- **One seam.** Every `Session` method ends in `@transport.call_tool(name:, arguments:, meta:)` ([session.rb:137](../../portage-ucp-client/lib/portage/ucp/client/session.rb#L137)). A new transport only has to implement that.
- **Same names.** The REST OpenAPI's `operationId`s (`https://ucp.dev/2026-08-25/services/shopping/rest.openapi.json`) are exactly our action names (`create_checkout`, `get_cart`, `search_catalog`, ...). The transport is a lookup table.
- **Same bodies, minus the wrapper.** REST bodies are the bare object (`#/components/schemas/checkout`). MCP wraps the same object as `{"checkout": {...}}`. `UcpWireShape` already builds the inner object, so REST unwraps it.
- **Same responses.** REST returns `checkout_response`/`cart_response`/... directly, which is what `ToolResult.extract` already pulls out of MCP's `structuredContent`.
- **No new dependency.** `faraday` is already a runtime dependency of `portage-ucp-client`.
- **Every app caller goes through `Client.discover`** (`buy.rb`, `find.rb`, `handoff_reconciler.rb`, `payment_methods.rb`, `browser_import/prober.rb`, `index/builder.rb`), so the app picks REST up for free once discovery chooses it. The one exception is `offer_sources.rb:135`, which calls `Client.connect(url:)` directly.

## Wire mapping (2026-08-25)

| Action | Verb + path | Body |
|---|---|---|
| `search_catalog` | `POST /catalog/search` | `catalog_search_request` |
| `lookup_catalog` | `POST /catalog/lookup` | `catalog_lookup_request` |
| `get_product` | `POST /catalog/product` | `catalog_get_product_request` |
| `create_cart` | `POST /carts` | `cart` |
| `get_cart` | `GET /carts/{id}` | none |
| `update_cart` | `PUT /carts/{id}` | `cart` |
| `cancel_cart` | `POST /carts/{id}/cancel` | none |
| `create_checkout` | `POST /checkout-sessions` | `checkout` |
| `get_checkout` | `GET /checkout-sessions/{id}` | none |
| `update_checkout` | `PUT /checkout-sessions/{id}` | `checkout` |
| `complete_checkout` | `POST /checkout-sessions/{id}/complete` | `checkout` (payment) |
| `cancel_checkout` | `POST /checkout-sessions/{id}/cancel` | none |
| `get_order` | `GET /orders/{id}` | none |

Paths are relative to the service entry's `endpoint`. The MCP `meta` object becomes headers instead of body fields:

- `UCP-Agent: profile="<agent profile URL>"` (RFC 8941 dictionary, **required** on every call). Same `MissingAgentProfileError` as Http when `meta[:agent_profile]` is missing.
- `Idempotency-Key: <uuid>` on every mutating call. `Session#call` already generates it.
- `Content-Type`/`Accept: application/json`, plus the caller's `headers:` (User-Agent, and `Authorization`/`X-API-Key` when a store hands out a credential, as #178's does).

`link_identity` and the payment-enrollment actions have no REST operation in 2026-08-25. On REST they raise `UnsupportedWireShapeError` naming the action, and `Session#advertises?` is unchanged.

## Decisions

- **When a store offers both, prefer MCP.** Every store we've tested live (Shopify's rollout) is MCP, and the reshaping there is proven. REST is the fallback, so nothing changes for existing stores. Within a transport, the newest `version` still wins.
- **Errors look the same.** A non-2xx REST response raises the same `ServerError` Http raises, carrying the UCP error body's message. The `complete_checkout` permission refusal maps to `PaymentPermissionError` through the same `permission_refusal?` check. Callers keep their existing `rescue`s.
- **`Client.connect` gets `transport: :mcp | :rest`** (default `:mcp`). `discover` passes the one it picked. `Session#transport_name` exposes it for `check`/`doctor` output.
- **Response signatures** (`Signature`/`Content-Digest`) are not verified in this plan. The Http transport doesn't verify them either.

## Phases

One phase per session, delegated to a Sonnet subagent, each ending with `LC_ALL=en_US.UTF-8 bundle exec rspec && bundle exec rubocop` green in every touched gem, a design-log entry, a progress-log row here, a commit on branch `ucp-rest-transport`, and a restart prompt.

**Phase 1 ✅: `Transports::Rest`** (`portage-ucp-client`). Add `transports/rest.rb` with the table above and `call_tool`, reusing `UcpWireShape` for the inner body and unwrapping the capability key. Faraday connection with `proxy:` handled the same way as Http. Add header mapping, error mapping and the unsupported-action error. Specs stub HTTP (no live calls) and cover each row of the table, the headers, a 4xx/5xx mapped to `ServerError`, the permission refusal and a missing profile.

**Phase 2: discovery picks the transport** (`portage-ucp-client`). Teach `mcp_endpoint` to become `service_endpoint` returning `[transport, endpoint]`: MCP first, then REST, otherwise `ManifestShapeError` with the message listing the transports it saw. Add `connect(transport:)` and `Session#transport_name`. Specs: an MCP-only manifest (unchanged), a REST-only one (the #178 document, saved as a fixture), both (MCP wins), neither, and the flat legacy manifest. Changelog entry.

**Phase 3: the app** (`portage-cli`, buyer MCP server). Make `offer_sources.rb` go through the same transport choice. Have `portage check`/`doctor` print the transport it connected over. Update the `buy.rb` warning text if it still implies MCP. Raise the gemspec to `portage-ucp-client ~> 0.8` (the CLI now needs `transport_name`). Run one CLI spec per command against a stubbed REST-only store, so `buy`, `find` and `check` are proven end to end, not just the transport. Docs: `docs/well-known-ucp.md`, `docs/library-usage.md`, `docs/spec-conformance.md`, `docs/capability-coverage.md`.

**Phase 4: live interop against #178.** Needs the restricted test credential from the issue author, passed in `headers:` at run time and never written to the repo or config. Run discovery, `create_checkout` for the $29 demo item, check the total, `get_checkout`, `cancel_checkout`. Record the results in the design log and post a summary on the issue (ask first). Fix anything it turns up before the release.

**Phase 5: release set 0.23.0.** Follow the `release` skill:

| Gem | Now | Next | Why |
|---|---|---|---|
| `portage-ucp-client` | 0.7.0 | 0.8.0 | New transport, `connect(transport:)`, `Session#transport_name` |
| `portage-cli` | 0.15.0 | 0.16.0 | REST stores work across the commands; needs client `~> 0.8` |
| `portage-ucp` and the adapter gems | | unchanged | No server-side change |
| `portage-ucp-webmcp` | | unchanged | Its `~> 0.6, >= 0.6.2` range already admits client 0.8 |

Pins: `Dockerfile` (portage-cli 0.16.0), `server.json` (version bump plus image tag). `Dockerfile.store`/`server.store.json` stay put. The buyer-image smoke test still expects 14 tools.

## Out of scope

- **Serving REST from Portage stores.** `portage-ucp` only serves MCP. A Rack REST endpoint for stores is its own plan.
- **Verifying REST response signatures.**
- **A2A and Embedded transports.**
- **Preferring REST over MCP** once REST has live miles. That's a one-line flip later.

## Open questions

- Does any app code read `Session` internals that assume MCP (`@client`, tool listing)? Phase 3 greps for it.
- Should `portage check` try both transports when a store offers both? It's not needed for #178, so the default is no.

## Progress log

| Date | Phase | Result |
|---|---|---|
| 2026-11-18 | Plan | Written from the #178 discovery doc and the 2026-08-25 REST OpenAPI. |
| 2026-11-18 | 1 | `Transports::Rest` added with 28 specs (client suite 79 to 107), rspec and rubocop green. Design log 66. |
