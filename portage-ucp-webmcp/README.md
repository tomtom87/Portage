# portage-ucp-webmcp

[WebMCP](https://webmachinelearning.github.io/webmcp/) for
[`portage-ucp`](https://github.com/tomtom87/Portage/tree/main/portage-ucp), as a
**transport**, not a commerce backend. WebMCP lets a web page register tools on
`document.modelContext` for an agent running in the browser to call. This gem
makes that page one more way to reach the existing `Adapter` contract, next to
classic MCP (stdio, Streamable HTTP) and native UCP.

```
                         ┌── stdio / Streamable HTTP ──┐
Agent ── Session ────────┤── native UCP (HTTP) ────────┤── Mcp::Server ── Dispatcher ── Adapter
                         └── WebMCP (a browser page) ──┘
```

Two halves, usable separately:

| Half | Side | What it does |
|---|---|---|
| Inbound | Merchant | Registers a Portage-powered store's catalog/cart/checkout tools on its pages via `document.modelContext`. Each tool call POSTs back to the store, into the same `Portage::Ucp::Mcp::Server` every other transport uses. |
| Outbound | Agent | A `portage-ucp-client` transport that finds and calls the WebMCP tools **any** page registers, Portage-powered or not, through the browser driver you already run. |

The `Adapter` stays the single source of truth. The tool list comes from the
`CapabilityRegistry`, as it does for MCP. Nothing commerce-related runs in the
browser.

## Inbound: expose your store to browser agents

```ruby
require "portage/ucp/webmcp"

catalog = Portage::Ucp::WebMcp::ToolCatalog.new(
  adapter: adapter,
  authenticator: MyCookieAuthenticator.new # same Authenticator contract as MCP
)

# config.ru
map("/ucp") { run Portage::Ucp::WebMcp::Rack::App.new(catalog: catalog) }

# Rails
mount Portage::Ucp::WebMcp::Rack::App.new(catalog: catalog), at: "/ucp"
```

```html
<script src="/ucp/webmcp.js" defer></script>
```

`Rack::App` serves two routes under its mount point:

| Route | Serves |
|---|---|
| `GET /webmcp.js` | The page script (`Registrar`). It registers each tool on `document.modelContext`, or on `navigator.modelContext` in earlier-draft browsers. |
| `POST /webmcp` | Its tool calls (`Rack::CallEndpoint`). One stateless JSON-RPC `tools/call` in, one result out, answered by the catalog's `Mcp::Server`. |

### What the page registers

`ToolCatalog` decorates the MCP server's generated tools for browser agents:

- Readable descriptions and typed JSON Schemas. `Mcp::Server` can only name
  parameters, so every property there is `{}`.
- WebMCP annotations: `readOnlyHint` for reads, and `consequentialHint` for
  `cancel_order`, `refund_order`, `request_return` and `complete_checkout`.
- `idempotency_key` is optional. The page generates one per mutating call when
  the agent leaves it out.

What the catalog exposes:

- **Capabilities:** standard `dev.ucp.shopping.*` capabilities only, without
  identity linking. Tools that take an OAuth token or manage stored credentials
  (saved payment methods, saved addresses, shopper-data deletion, payment
  enrollment) are left out. Widen with `capabilities: ->(name) { ... }`.
- **`complete_checkout`:** left out (`DEFAULT_EXCEPT`). Over any server
  transport it runs the Dispatcher's payment `Confirmer`. That defaults to
  `Confirmer::Terminal`, which prompts on the server's stdin, and
  `Mcp::Server.build` has no seam to replace it. On a web request that prompt
  holds the request until it times out and denies. In the browser the shopper
  is present anyway: the agent builds the checkout, and the shopper pays in the
  store's own checkout (the checkout's `links` or `continue_url`). Opt in with
  `except: []` only after you have solved confirmation.
- **Filters:** `only:`, `except:` and `prefix:` (for example `prefix: "acme."`
  when the page registers WebMCP tools of its own).

`Rack::CallEndpoint` enforces the same filter on the server side. An action the
page doesn't register can't be reached by POSTing its name.

A second `GET /webmcp.js` (a Turbo/SPA reload re-running the script tag)
re-registers cleanly: it waits for the previous generation's own in-flight
`registerTool` calls to settle and unregister before registering the same
names again, bounded by `registrar_options: { reregister_wait_ms: }` (default
2000) so a previous generation that never settles can't block the page
forever.

### Security

The endpoint is browser-facing and the page's cookies go with every call. For
that reason it is stricter than a plain MCP endpoint:

- **JSON bodies only.** A cross-site `<form>` can't reach the endpoint without a
  CORS preflight.
- **`Origin` required.** The header must match `allowed_origins`. The default is
  the endpoint's own origin. A request with no `Origin` is refused unless you
  pass `require_origin: false`.
- **Two methods only.** `tools/call` and `tools/list`, and only for exposed
  actions.
- **Same guards as MCP.** Mutating calls go through your `Authenticator` and
  `RateLimiter`, exactly as over MCP. The `server_context` they receive carries
  `transport: "webmcp"`, `request:` (the `Rack::Request`, for your session
  cookie or a CSRF header) and `origin:`.

Put a CSRF token on the page's requests with
`registrar_options: { headers: { "x-csrf-token" => token } }` and check it in
your `Authenticator`.

For a storefront on another origin than the endpoint, use this pattern:

```ruby
Portage::Ucp::WebMcp::Rack::App.new(
  catalog: catalog,
  call_options: { allowed_origins: ["https://shop.example"] },
  registrar_options: { endpoint: "https://api.shop.example/ucp/webmcp", credentials: "include" }
)
```

The endpoint then answers the CORS preflight and sends credentialed CORS
headers for that origin only.

### Request limits

Two more limits bound a single `POST /webmcp`, on top of the `Origin`/method/
content-type checks above. Every rejection — these two, the checks above, and
a JSON-RPC error `dispatch` itself returns — answers with the same JSON-RPC
error envelope, so a caller never needs to branch on HTTP status to read why
a call failed.

- **`max_body_bytes:`** (default 1MiB). A `Content-Length` over the cap is
  refused with `413` before anything is read. Otherwise at most
  `max_body_bytes + 1` bytes are ever read off the request body, so a body
  with no `Content-Length` (or one that under-reports) still can't be
  buffered in full first.
- **`call_timeout:`** (default 30 seconds, `nil` disables it). Bounds one
  `tools/call`/`tools/list` dispatch into the catalog's `Mcp::Server#handle`.
  A call that runs past it answers a JSON-RPC error rather than holding the
  browser's `fetch` (and the request thread) open indefinitely. This is a
  floor under the endpoint, not a replacement for your own `Adapter`/HTTP
  client timeouts — a slow adapter call still ties up the thread until it
  fires.

```ruby
Portage::Ucp::WebMcp::Rack::App.new(
  catalog: catalog,
  call_options: { max_body_bytes: 262_144, call_timeout: 10 }
)
```

### Content-Security-Policy

The registrar's script and its `fetch` calls need two directives, if your
store sets a CSP:

- **`script-src`**: allow the origin `GET /webmcp.js` is served from (usually
  your own, `'self'`). The script has no inline `<script>` body — it's a
  `src=` include — so no `'unsafe-inline'` or nonce is needed for it.
- **`connect-src`**: allow the origin `POST /webmcp` targets. For a
  same-origin endpoint, `'self'` already covers it. For the cross-origin
  pattern above (`registrar_options: { endpoint: "https://api.shop.example/..." }`),
  add that origin explicitly: `connect-src 'self' https://api.shop.example`.
  Also add it for every origin passed to `exposed_to:` if that agent surface
  itself calls the endpoint from a different frame's document.

Nothing here needs `'unsafe-eval'`: the registrar only calls `fetch` and
`document.modelContext.registerTool`, never `eval` or `new Function`.

### CSRF posture

`allowed_origins`/`Origin` checking (above) is the endpoint's primary CSRF
defense: a browser attaches the real `Origin` on every `fetch`, and page
script can't override it, so a cross-site page's request is rejected before
your `Authenticator` ever sees it — the same protection `SameSite` cookies
give a classic form POST, enforced here explicitly since the endpoint has to
work from a cross-origin storefront too (`allowed_origins:`).

If your `Authenticator` reads a session cookie (cookie-auth, `credentials:
"same-origin"` or `"include"`), also set a CSRF token, the same as you would
for any other cookie-authenticated POST endpoint: put it on the page's
requests with `registrar_options: { headers: { "x-csrf-token" => token } }`
and check `server_context[:request]` for it in your `Authenticator`, exactly
as `spec/support/store.rb` does in this gem's own specs. `Origin` checking
alone is not a substitute for this when the endpoint's `Authenticator` trusts
a cookie: a same-origin `Origin` only proves the request came from a page on
your site, not that the page is the one your store served (an XSS on another
page of the same origin, or a subdomain sharing the cookie's domain, can
still fetch same-origin).

### Browsers without WebMCP

When the page has no `modelContext`, the registrar does nothing. It records
`window.portageWebMcp.reason = "no_model_context"`. Pass
`registrar_options: { include_polyfill: true }` to install a minimal,
spec-shaped `document.modelContext` first. That helps agents that drive a
browser build without native WebMCP. A browser that has a native
implementation keeps it.

## Outbound: call any page's WebMCP tools from an agent

```ruby
require "portage/ucp/webmcp"

page = Ferrum::Browser.new.create_page
page.command("Page.addScriptToEvaluateOnNewDocument", source: Portage::Ucp::WebMcp.polyfill_js) # optional
page.go_to("https://shop.example/products/mug")

session = Portage::Ucp::WebMcp.connect(
  bridge: Portage::Ucp::WebMcp::Bridges::ScriptEvaluator.ferrum(page)
)
session.search_catalog(query: "mug")
session.create_checkout(line_items: [{ product_id: "mug", quantity: 1 }])
```

`session` is the same `Portage::Ucp::Client::Session` that
`Client.for_adapter`, `.connect` and `.discover` return. It has the same
methods, the same client-side `PaymentTokenGuard` and the same `ServerError`
on a tool error. The caller doesn't need to know which transport it got.

### Browser drivers

No driver gem is a dependency. `ScriptEvaluator` takes any callable that
evaluates a JavaScript expression in the page and returns what its promise
resolves to. Helpers exist for three drivers:

| Driver | Bridge |
|---|---|
| Ferrum | `ScriptEvaluator.ferrum(page)` |
| Playwright (`playwright-ruby-client`) | `ScriptEvaluator.playwright(page)` |
| Selenium WebDriver | `ScriptEvaluator.selenium(driver)` |
| Anything else | `ScriptEvaluator.new(evaluate: ->(js) { ... })`, or `WebMcp.connect(evaluate: ...)` |

A browser extension, a raw CDP session or a remote grid can write its own
bridge instead. Any object with `#list_tools` and `#execute_tool(name, input)`
works.

### WebMCP surfaces

The consumer script tries these in order:

1. `document.modelContext`, or `navigator.modelContext`, with `getTools()` and
   `executeTool()`. This is the current spec.
2. `navigator.modelContextTesting`, with `listTools()` and
   `executeTool(name, json)`. This is the testing API from early browser builds.
3. `listTools()` and `callTool({ name, arguments })`, the shape that some
   userland polyfills use.

A page that registers tools but offers none of these to a consumer can still be
read. Inject `WebMcp.polyfill_js` before navigation so the page registers into
something the consumer can list.

### Stores that don't run Portage

`Transport` does not assume that the page was built with this gem:

- **Tool names.** An action resolves to `tool_names[action]` first, then to
  `"#{prefix}#{action}"`, then to the action itself. Map a store's own names:
  `WebMcp.connect(bridge:, tool_names: { search_catalog: "findProducts" })`. A
  miss reads the page again once (for tools registered late), then raises
  `ToolNotFoundError`, which lists what the page does register.
- **Argument shape.** The shape comes from each tool's own `inputSchema`. If
  its properties nest under `catalog`, `cart` or `checkout`, or it takes `id`
  and `meta`, it is a real-UCP-shaped tool. It gets the same body that
  `Transports::Http` builds for native UCP (the code is shared through
  `Transports::UcpWireShape`). Other tools get Session's flat arguments, as
  over stdio. Force one shape with `wire: :ucp` or `wire: :flat`.
- **Results.** An MCP-style `CallToolResult` is unwrapped the same way as over
  stdio or HTTP, and `isError` raises `ServerError`. A JSON string (the spec's
  `executeTool` resolves to one) is parsed. Anything else is returned as it is.
- **Re-registration.** Some pages drop all their tools and register them again
  while they re-render. A call to a tool that vanished that way waits up to
  `reregister_wait:` (default 2 seconds) for it to come back, then retries.
  The call never ran the first time, so the retry is safe. The wait blocks
  the calling thread; see "Timeouts" below.

### Timeouts

Two limits bound an outbound call, and both block the thread that made it:

- **The browser driver's own timeout** bounds each round trip to the page.
  `ScriptEvaluator.ferrum(page, timeout: 30)` passes its `timeout:` (default
  30 seconds) to `evaluate_async`. Playwright and Selenium use the page's or
  driver's own script timeout, so set it there. A driver that times out
  raises, and the error surfaces as `BridgeError`.
- **`reregister_wait:`** (default 2 seconds, `WebMcp.connect(...,
  reregister_wait:)`) bounds the wait for a tool the page dropped mid-call.
  It's a plain `sleep`, polling every 0.25 seconds. One monotonic deadline
  covers the whole call: it's set before the first attempt, a retry never
  resets it, the retried calls count against it, and no sleep runs past it.
  A miss costs at most `reregister_wait:` plus the one driver round trip in
  flight when it expires. Pass `reregister_wait: 0` to fail on the first
  miss, or make the call off a thread that can't afford to block.

### Shopify storefronts

Checked live on 2026-09-23: 6 of 8 Shopify storefronts tried (ColourPop,
tentree, Kylie Cosmetics, Brooklinen, Allbirds, Billabong) register the same 11
WebMCP tools of their own. Gymshark and Fashion Nova registered none. The
tools take UCP-shaped arguments, so `wire: :auto` picks the UCP shape. Two
names differ from Session's:

```ruby
session = Portage::Ucp::WebMcp.connect(bridge: bridge, tool_names: { create_cart: "add_to_cart" })
session.search_catalog(query: "hoodie")          # page tool: search_catalog
session.get_product(product_id: product["id"])   # page tool: get_product, variants included
session.create_cart(line_items: [{ product_id: variant["id"], quantity: 1 }]) # adds to the browser's cart
session.get_cart(cart_id: "current")             # the browser's cart; cart_id is ignored
```

Things to know about these tools:

- The cart is the browser session's own cart, so `add_to_cart` returns no cart
  id and adds to what is already there.
- Search results carry no variants. Call `get_product` for variant ids.
- Right after `add_to_cart`, the page's cart tools can fail for a second or two
  with `Standard Actions are not available ... Try again`. Wait and call again.
- `update_cart_lines` addresses existing cart lines by line id, not by variant.
  `proceed_to_checkout` navigates the browser to Shopify checkout, where the
  shopper pays. Neither maps onto a Session method.

### Errors

All errors are under `Portage::Ucp::Client::Error`, so existing `rescue` blocks
still catch them.

| Error | When |
|---|---|
| `WebMcp::BridgeError` | The page has no WebMCP surface, the driver failed, or the result couldn't be read. It quotes at most 300 characters of the driver's own error. |
| `WebMcp::ToolNotFoundError` | No page tool answers the action. `#available` lists what the page registers. |
| `Client::ServerError` | The tool ran and failed: `isError`, the page's tool threw, or the endpoint's own `call_timeout:` fired. |

## Development

```bash
bundle exec rspec && bundle exec rubocop
```

The browser-side scripts are plain `.js` files under
`lib/portage/ucp/webmcp/assets/`. Specs tagged `:node` run them unmodified in
a node process that stands in for a browser tab
(`spec/support/node_browser.{js,rb}`). The fetches of that tab are answered by
the real `Rack::App`. This makes the round-trip specs go page, then endpoint,
then `Mcp::Server`, then `ReferenceAdapter`, with nothing mocked. They also
check that WebMCP returns the same documents as the in-process Loopback
transport. These specs are skipped when `node` isn't installed.

`spec/portage/ucp/webmcp/real_browser_spec.rb` runs the same register ->
call -> re-register sequence against a real, headless Chrome (via `ferrum`)
instead of the node stand-in, for a second confirmation against an actual
browser's WebMCP/fetch behavior. It's slow and needs Chrome or Chromium
installed, so it's excluded by default:

```bash
REAL_BROWSER=1 bundle exec rspec spec/portage/ucp/webmcp/real_browser_spec.rb
```
