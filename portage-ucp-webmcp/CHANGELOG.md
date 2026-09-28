# Changelog

All notable changes to this project are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.0.0/); this project is
pre-1.0, so APIs may still shift between minor versions.

## [Unreleased]

- **Docs for Phases 1-3** (docs/plans/webmcp-universal-outbound.md Phase 4,
  no code change): the README's "Stores that don't run Portage" section now
  documents `Presets`/`preset:`, `Matcher`/the read-vs-mutating confirm
  rule, the fingerprint-keyed confirmed-mapping store, and a new "Approved
  autofill of the store's checkout" section covering `Autofill`'s outcomes
  and `Preset#checkout_selectors`. None of this had been written up before
  now even though it shipped in earlier phases.
- **Checkout autofill** (docs/plans/webmcp-universal-outbound.md Phase 3):
  `Bridges::ScriptEvaluator#autofill(fields, selectors:)` fills a checkout
  page's own contact/shipping fields directly — by `autocomplete` attribute,
  never a WebMCP tool call — via a new `assets/autofill.js`, and picks the
  cheapest shipping rate among same-named radio groups it can read a price
  from. Never touches a field whose own `autocomplete` is payment-shaped
  (`cc-*`/`transaction-*`) or whose `type` is hidden/password, regardless of
  what's asked for; never clicks a submit/pay control; stops and reports
  `blocked` on the first sign of a CAPTCHA/challenge, without trying to
  solve or route around it. `ScriptEvaluator.ferrum`/`.playwright`/
  `.selenium` all take a new `headless:` (default `nil`, meaning "unknown"),
  exposed as `#headless?`. `WebMcp::Autofill.call(bridge:, fields:,
  selectors:)` is the Ruby-side gate in front of it: `:needs_headed_browser`
  when the bridge is headless or never says (unknown is treated as
  headless — a shopper who can't see the browser can't pay in it either),
  `:unsupported` for a hand-rolled Bridge with no `#autofill` at all,
  `:blocked` when the page script signals a challenge, `:filled` otherwise
  (with `#filled`/`#unmatched`/`#rate`). `Presets::Preset` gained
  `checkout_selectors` (default `{}`), a platform's fallback CSS selectors
  per autocomplete token — Shopify's is empty pending a live check (no
  browser or live storefront available this session; noted as pending in
  the plan's Progress log). Everything upstream of this — the opt-in gate,
  the shopper-approval prompt, building `fields` from `PORTAGE_SHIP_*` — is
  `portage-cli`'s job (`WebmcpAutofillMode`, `WebmcpAutofillConfirm`,
  `WebmcpAutofillFields`); this gem never reads shopper data itself.
- **Schema matching for unknown pages** (docs/plans/webmcp-universal-outbound.md
  Phase 2): `WebMcp::Matcher.propose(tools)` proposes a `tool_names:` mapping
  for a page `Presets.detect` doesn't recognize, scoring each of the page's
  tools against every UCP action it might be by name-token overlap
  (`findProducts` ↔ `search_catalog`), input-schema shape (a `query` string
  → search; `product_id`/`variant_id` + `quantity` → add to cart), and the
  `readOnlyHint` annotation — never a tool's `description`, which is
  untrusted page content. Returns a `Proposal` (`tool:`, `confidence:`,
  `reason:`) per action scored above a floor; an action nothing scores
  against is simply absent. No LLM in this gem. `Matcher.tool_names(proposal)`
  flattens a proposal to the plain `tool_names:` shape. Confirming a
  proposal, and persisting a confirmed mapping, is `portage-cli`'s job
  (`WebmcpMappingConfirm`, `WebmcpMappings`) — nothing here calls a tool or
  writes anything.
- `WebMcp::Fingerprint`, extracted from `Presets.detect`'s own name-sorting:
  `.names(tools)` (sorted tool names, what `Presets.detect` matches against)
  and `.for(tools)` (a digest of every tool's name *and* its own input
  schema — what `portage-cli`'s confirmed-mapping store keys a Phase 2
  mapping by, so a lookalike page with the same tool names but a different
  schema shape gets a different fingerprint).
- `WebMcp.connect` with no `capabilities:` now derives them from the tools
  the page registers (`WebMcp::Capabilities`), so `Session#advertises?`
  answers `true`/`false` instead of `nil`. This reads the page once inside
  `connect`, so a `BridgeError` can now raise from `connect` itself.
  `Transport#answers?(action)` reports whether a page tool answers an
  action after `tool_names:`/`prefix:` resolution.
- **Platform presets** (docs/plans/webmcp-universal-outbound.md Phase 1):
  `WebMcp.connect` takes a new `preset:` (default `:auto`), which detects a
  known platform from the exact set of tool names the page registers right
  now — never from page text, which is untrusted content a page could
  forge — and applies its `tool_names:`/`wire:`. `nil` turns presets off;
  a Symbol (`:shopify`) forces one without reading the page to detect it.
  An explicit `tool_names:` still wins over the preset's own, key by key.
  `WebMcp::Presets::SHOPIFY` is the first entry: `tool_names: {create_cart:
  "add_to_cart"}`, and a `handoff_checkout: "proceed_to_checkout"` naming
  the tool that only navigates the browser to Shopify's own checkout. Its
  fingerprint is the 11 tools seven live Shopify storefronts registered
  on 2026-09-28, all with identical input schemas.
- `WebMcp::Capabilities.for` takes a new `handoff_checkout:` (a preset's
  hand-off-only checkout tool name) — a page that answers it now counts as
  advertising checkout even with no `create_checkout` tool at all.
- `Bridges::ScriptEvaluator#location` reads the tab's current URL
  (`window.location.href`) through the same `evaluate:` callable every
  other call uses. Optional on the Bridge contract — used by `portage-cli`
  `Buy`'s hand-off checkout path to read the checkout URL after a tool
  that only navigates the tab, when the tool's own result carries none.

## [0.1.1] - 2026-09-24

- `Rack::CallEndpoint` resolves the caller through core's
  `Rack::ForwardedRequest`: `X-Forwarded-*`/`Forwarded` are trusted only
  from a configured `trusted_proxies` list, `server_context[:client_ip]`
  (seen by the rate limiter and authenticator) is the right-most untrusted
  hop, and `X-Forwarded-Host` never widens `allowed_origins`. Requires
  `portage-ucp` `~> 0.10`.
- An outbound call now waits out a tool that answers the page isn't ready,
  as it already waited out one the page dropped. Shopify storefronts reload
  after their own `add_to_cart`/`cancel_cart` and, until they're back, every
  cart tool answers "Standard Actions are not available… Try again" (as an
  `isError` result, a JSON string or a thrown error), which surfaced as
  `ServerError` (seen live on thelightyard.co.uk and burton.com).
  Only the messages in `PageWait::NOT_READY` are retried; any other tool
  error is still raised at once, so a mutation can't run twice. The default
  `reregister_wait:` goes from 2s to 5s: with several browsers busy the tools
  took up to ~3s to come back.

- `Rack::CallEndpoint` no longer raises `TypeError` when a `tools/call` body
  sends `params` as a string, number or boolean instead of an object; it
  answers `-32602 Invalid params` like any other bad call. A top-level
  JSON-RPC batch (an array) and a non-string `method` were already handled
  without crashing; both now have specs.
- `Rack::CallEndpoint` takes `max_body_bytes:` (default 1MiB). A
  `Content-Length` over the cap is refused with `413` before anything is
  read; otherwise at most `max_body_bytes + 1` bytes are ever read off the
  body, so a missing or understated `Content-Length` can't be used to buffer
  an unbounded body first.
- `Rack::CallEndpoint` takes `call_timeout:` (default 30s, `nil` disables it),
  bounding one dispatch into the catalog's `Mcp::Server#handle` so a slow
  adapter call can't hold a browser's `fetch` open indefinitely. Every
  rejection this endpoint answers — origin/method/content-type/size checks
  included — now shares one JSON-RPC error envelope shape.
- `registrar.js` no longer races a Turbo/SPA reload against itself: a second
  `GET /webmcp.js` now awaits the previous generation's own in-flight
  `registerTool` calls (and that generation's `unregister`) before
  registering the same names again, bounded by `reregister_wait_ms:`
  (default 2000) so a previous generation that never settles can't block the
  page forever. Previously, a fast-enough reload could start registering
  before the first generation had actually dropped anything, and the second
  generation's calls would collide on every tool name.
- Security review: added a spec confirming `ScriptEvaluator` can't be broken
  out of by a tool name or argument containing JS-breaking characters (it's
  JSON-encoded, never interpolated into the expression's own syntax).
  README: new "Content-Security-Policy" and "CSRF posture" sections, and a
  "Request limits" section documenting `max_body_bytes:`/`call_timeout:`.
- `spec/portage/ucp/webmcp/real_browser_spec.rb`: registrar.js register ->
  tool call -> re-register against a real, headless Chrome (via a new
  `ferrum` dev dependency), not just the `:node` specs' stand-in tab.
  Excluded by default (slow, needs Chrome installed); run with
  `REAL_BROWSER=1 bundle exec rspec spec/portage/ucp/webmcp/real_browser_spec.rb`.

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
