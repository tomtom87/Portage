# Changelog

All notable changes to this project are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.0.0/); this project is
pre-1.0, so APIs may still shift between minor versions.

## [0.1.0] - 2026-09-23

- Initial release. WebMCP as a transport to the existing `Adapter` contract.
- The registrar reports a non-JSON reply from its endpoint (a proxy's HTML
  error page) as `tools/call to <endpoint> returned a non-JSON response
  (<status>)`, rather than a bare `Unexpected token '<'`.
- Inbound (merchant side): `ToolCatalog` derives the tools a page registers
  from `Portage::Ucp::Mcp::Server`'s own tools/list. It adds readable
  descriptions, typed parameter schemas and WebMCP annotations.
  `Rack::App` serves the page registrar (`GET /webmcp.js`) and its call
  endpoint (`POST /webmcp`). The endpoint accepts JSON only, requires a
  matching `Origin`, and allows only `tools/call`/`tools/list` for exposed
  actions. It hands the Rack request to the Authenticator. OAuth-token and
  stored-credential tools are left out by default. `complete_checkout` is
  also left out by default, because the Dispatcher's default Terminal
  Confirmer would block the web request.
- Outbound (agent side): `Transport` is a `portage-ucp-client` transport over
  any page's WebMCP tools. It supports the spec surface, the
  `modelContextTesting` surface and the userland-polyfill surface. It
  resolves tool names with `tool_names:`/`prefix:`, and it picks flat or
  real-UCP argument shapes from each tool's schema.
  `Bridges::ScriptEvaluator` works with Ferrum, Playwright, Selenium or any
  JavaScript-evaluating callable. `WebMcp.connect` returns a
  `Client::Session`.
- `WebMcp.polyfill_js`: a minimal, spec-shaped `document.modelContext` for
  browsers without native WebMCP.
- `Transport` waits out a page that drops and re-registers its tools
  mid-call (`reregister_wait:`, default 2s) instead of raising
  `ToolNotFoundError` for a tool it had just found. Confirmed live on
  Shopify storefronts, whose own `add_to_cart` tool leaves the page with no
  tools for about 500ms.
  - The wait is a blocking `sleep`, now documented under the README's
    "Timeouts". Its one deadline covers the whole call, and the last poll
    no longer sleeps past it: a 0.25s poll started 0.1s before the deadline
    now sleeps 0.1s.
- `ScriptEvaluator`'s `BridgeError` quotes at most 300 characters of the
  driver's own error (and of an unreadable reply), the same cap
  `portage-ucp-decision` uses for Jev. A Selenium failure can carry a DOM
  dump or a stack trace, which used to land whole in an agent's context.
