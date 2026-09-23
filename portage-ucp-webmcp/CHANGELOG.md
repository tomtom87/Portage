# Changelog

All notable changes to this project are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.0.0/); this project is
pre-1.0, so APIs may still shift between minor versions.

## [0.1.0] - Unreleased

- Initial release. WebMCP as a transport to the existing `Adapter` contract.
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
