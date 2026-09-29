# portage-ucp-webmcp API

`portage-ucp-webmcp` (0.2.0) connects UCP to WebMCP, the browser API where a page registers tools on `document.modelContext`.

Use the outbound half when your agent drives a store's page through a browser. Use the inbound half when you run a store and want browser agents to reach your `Adapter`. It builds on [portage-ucp-client](portage-ucp-client.md) and the core gem ([portage-ucp](portage-ucp.md)).

```ruby
require "portage/ucp/webmcp"
```

All classes live under `Portage::Ucp::WebMcp`.

## Outbound: drive a page's tools

### connect

`WebMcp.connect(bridge: nil, evaluate: nil, capabilities: nil, preset: :auto, **transport_options)` returns a `Portage::Ucp::Client::Session` over the page's tools.

| Argument | Notes |
|---|---|
| `bridge:` | Any bridge object (see "Bridge contract"). |
| `evaluate:` | A callable that evaluates a JavaScript expression in the page and returns what its promise resolves to. Builds a `Bridges::ScriptEvaluator`. Ignored if `bridge:` is given. |
| `capabilities:` | Array of capability names. `nil` derives them from the tools the page registers now. |
| `preset:` | `:auto` (default) detects a known platform from the page's tool names. `nil` turns presets off. A Symbol such as `:shopify` forces that preset without reading the page. |
| `**transport_options` | `prefix:`, `tool_names:`, `wire:`, `reregister_wait:`, forwarded to `Transport`. Yours win over a preset's: `tool_names:` key by key, `wire:` outright. |

It raises `ArgumentError` if you pass neither `bridge:` nor `evaluate:`. With `capabilities:` nil or `preset: :auto`, it reads the page during `connect`, so it can raise `BridgeError`.

Also: `WebMcp.polyfill_js` returns a script that installs a spec-shaped `document.modelContext` where the browser has none. Inject it before navigation.

```ruby
session = Portage::Ucp::WebMcp.connect(
  bridge: Portage::Ucp::WebMcp::Bridges::ScriptEvaluator.ferrum(browser.page, headless: false)
)
session.search_catalog(query: "mug")
```

Session methods work as documented for the client. Behind WebMCP a missing `agent_profile` is not an error.

Source: `portage-ucp-webmcp/lib/portage/ucp/webmcp.rb`

### Transport

`Transport` is the client transport behind that session (`call_tool(name:, arguments:, meta: nil)`). Build it yourself only for a custom setup.

| Method | Signature | Returns | Notes |
|---|---|---|---|
| `new` | `Transport.new(bridge:, prefix: nil, tool_names: {}, wire: :auto, reregister_wait: Transport::REREGISTER_WAIT)` | `Transport` | `wire:` must be `:auto`, `:flat` or `:ucp`, else `ArgumentError`. `reregister_wait` defaults to 5.0 seconds. |
| `bridge` | `transport.bridge` | Bridge | Reader. |
| `tools` | `tools` | `Array<Hash>` | Tools the page registers, cached. |
| `refresh!` | `refresh!` | `self` | Clears the cache. |
| `answers?` | `answers?(action)` | Boolean | Whether a cached tool answers the action. No re-read. |
| `call_tool` | `call_tool(name:, arguments:, meta: nil)` | The tool's result | Raises `ToolNotFoundError` if no tool answers. |

How it works:

- Tool lookup for an action: `tool_names[action]`, then `"#{prefix}#{action}"`, then the action name. A miss re-reads the page once before raising.
- With `wire: :auto`, a tool whose `inputSchema` properties include `catalog`, `cart` or `checkout` (or both `id` and `meta`) gets the real-UCP body the HTTP transport builds. Any other tool gets flat arguments.
- The result may be an MCP-style `CallToolResult` (unwrapped like stdio and HTTP), a JSON string (parsed) or anything else (returned as-is).
- If a page drops its tools while re-rendering, or a tool answers "not ready", the call waits up to `reregister_wait:` and retries. The wait is a plain `sleep`, so it blocks the thread.

Source: `portage-ucp-webmcp/lib/portage/ucp/webmcp/transport.rb`

### Bridge contract and ScriptEvaluator

A bridge is any object with `#list_tools` (an `Array<Hash>` with string keys) and `#execute_tool(name, input)` (the tool's raw result). `#location`, `#headless?` and `#autofill` are optional. Callers check `respond_to?` first.

`Bridges::ScriptEvaluator` is the bridge this gem ships. It needs no driver gem.

| Method | Signature | Returns | Notes |
|---|---|---|---|
| `new` | `ScriptEvaluator.new(evaluate:, headless: nil)` | `ScriptEvaluator` | `evaluate` must respond to `call`, else `ArgumentError`. |
| `ferrum` | `ScriptEvaluator.ferrum(page, timeout: 30, headless: nil)` | `ScriptEvaluator` | For a `Ferrum::Page`. |
| `playwright` | `ScriptEvaluator.playwright(page, headless: nil)` | `ScriptEvaluator` | For playwright-ruby-client. |
| `selenium` | `ScriptEvaluator.selenium(driver, headless: nil)` | `ScriptEvaluator` | For Selenium WebDriver. |
| `list_tools` | `list_tools` | `Array<Hash>` | |
| `execute_tool` | `execute_tool(name, input)` | Raw tool result | |
| `location` | `location` | `String` | The tab's `window.location.href`. |
| `headless?` | `headless?` | Boolean or nil | nil means "unknown". Autofill treats unknown as headless. |
| `autofill` | `autofill(fields, selectors: {})` | `Hash` | Keys `"blocked"`, `"filled"`, `"unmatched"`, `"rate"`. |

Errors from a bridge call: a failing driver, no WebMCP surface, or a non-JSON reply raises `BridgeError`. A tool the page does not register raises `ToolNotFoundError`. A tool that ran and failed raises `Portage::Ucp::Client::ServerError`.

Source: `portage-ucp-webmcp/lib/portage/ucp/webmcp/bridges/script_evaluator.rb`

### Errors

| Class | Superclass | Raised when |
|---|---|---|
| `Error` | `Portage::Ucp::Client::Error` | Base class. Client rescues still catch these. |
| `BridgeError` | `Error` | The page has no WebMCP surface, the driver's evaluate call failed, or the reply was not a JSON envelope. |
| `ToolNotFoundError` | `Error` | No page tool answers an action. `#available` lists the tool names the page does register. |

Source: `portage-ucp-webmcp/lib/portage/ucp/webmcp/errors.rb`

### Presets

A preset maps a known platform's tool names so you need no `tool_names:`. `Presets.detect` picks one only when the page's registered tool names are an exact match. It never reads page text.

| Item | Signature | Returns | Notes |
|---|---|---|---|
| `Presets::Preset` | `Struct` with `tool_names`, `wire`, `fingerprint`, `handoff_checkout`, `checkout_selectors` (keyword init) | | `checkout_selectors` returns `{}` if unset. |
| `Presets::ALL` | `{ shopify: SHOPIFY }` | Hash | |
| `Presets::SHOPIFY` | | `Preset` | `tool_names: { create_cart: "add_to_cart" }`, `wire: :auto`, `handoff_checkout: "proceed_to_checkout"`, an 11-name fingerprint. |
| `Presets.detect` | `Presets.detect(tools)` | `Symbol`, `nil` | nil for an unknown page, or a known platform whose tool set changed. |
| `Presets.fetch` | `Presets.fetch(name)` | `Preset` | Raises `KeyError` for an unknown name. |

Source: `portage-ucp-webmcp/lib/portage/ucp/webmcp/presets.rb`

### Matcher

For a page no preset recognises, `Matcher` proposes a `tool_names:` mapping from tool names, input-schema shape and `readOnlyHint`. It never reads a tool's `description`. It calls nothing and saves nothing. Have the shopper or your own logic confirm a proposal before you use it.

| Item | Signature | Returns | Notes |
|---|---|---|---|
| `Matcher::Proposal` | `Struct` with `tool`, `confidence`, `reason` (keyword init) | | `confidence` is 0.0 to 1.0, rounded to 2 places. |
| `Matcher.propose` | `Matcher.propose(tools)` | `Hash{String => Proposal}` | One entry per action with a match at or above `Matcher::MIN_CONFIDENCE` (0.3). Actions covered: `search_catalog`, `get_product`, `get_cart`, `create_cart`, `update_cart`, `create_checkout`. |
| `Matcher.tool_names` | `Matcher.tool_names(proposal)` | `Hash{String => String}` | Action to tool name. The shape `tool_names:` takes. |

Source: `portage-ucp-webmcp/lib/portage/ucp/webmcp/matcher.rb`

### Fingerprint

| Method | Signature | Returns | Notes |
|---|---|---|---|
| `Fingerprint.names` | `Fingerprint.names(tools)` | `Array<String>` | Sorted tool names. What `Presets.detect` compares. |
| `Fingerprint.for` | `Fingerprint.for(tools)` | `String` | SHA-256 hex digest over each tool's name and input schema. Use it to key a confirmed mapping so a lookalike page with different schemas cannot reuse it. |

Both accept string or symbol keys.

Source: `portage-ucp-webmcp/lib/portage/ucp/webmcp/fingerprint.rb`

### Capabilities

`Capabilities.for(transport, handoff_checkout: nil)` returns an `Array<String>` of capability names the page's tools add up to (`dev.ucp.shopping.catalog`, `.cart`, `.checkout`, `.order`). A capability counts when the page answers the action that starts it. A preset's `handoff_checkout` tool counts as checkout. `connect` calls this for you.

Source: `portage-ucp-webmcp/lib/portage/ucp/webmcp/capabilities.rb`

### Autofill

`Autofill.call(bridge:, fields:, selectors: {})` fills the checkout page's contact and shipping fields in the browser that holds the cart. It never fills payment fields and never submits. Your app decides whether to run it and builds `fields`. This gem reads no shopper data.

| Argument | Notes |
|---|---|
| `bridge:` | Needs `#autofill`, and `#headless?` returning `false`. |
| `fields:` | `Hash{String => String}` of autocomplete token to shopper-approved value. |
| `selectors:` | `Hash{String => String}` of fallback CSS selectors, for example `Presets::SHOPIFY.checkout_selectors`. |

It returns `Autofill::Result`, a Struct with `outcome`, `filled`, `unmatched`, `rate` and an `ok?` method (true when `outcome == :filled`).

| `outcome` | Meaning |
|---|---|
| `:filled` | Ran. `filled` and `unmatched` say what matched. Also returned, with empty lists, when `fields` is empty. |
| `:needs_headed_browser` | The bridge is headless, or never said it was not. |
| `:blocked` | A CAPTCHA or challenge is on the page. Nothing was touched. |
| `:unsupported` | The bridge has no `#autofill`. |

Source: `portage-ucp-webmcp/lib/portage/ucp/webmcp/autofill.rb`

## Inbound: expose your store to browser agents

### ToolCatalog

`ToolCatalog.new(adapter:, prefix: nil, only: nil, except: ToolCatalog::DEFAULT_EXCEPT, capabilities: ToolCatalog::DEFAULT_CAPABILITIES, **server_opts)` decides which tools a page registers. `server_opts` go to `Portage::Ucp::Mcp::Server.build` (`registry:`, `authenticator:`, `rate_limiter:`, `logger:`, `journal:`).

| Item | Notes |
|---|---|
| `DEFAULT_CAPABILITIES` | Lambda accepting `dev.ucp.shopping.*` except `dev.ucp.shopping.identity`. |
| `DEFAULT_EXCEPT` | `["complete_checkout"]`. Its payment confirmation prompt would wait on the server's stdin. Pass `except: []` to include it. |
| `prefix` | Prepended to every tool name, for example `"acme."`. |
| `only` | Array of action names to expose, or nil for all. |

| Method | Signature | Returns |
|---|---|---|
| `server` | `server` | The built `Mcp::Server`. |
| `tools` | `tools` | Frozen `Array<Hash>` of tool definitions. |
| `prefix` | `prefix` | String. |
| `exposes?` | `exposes?(action)` | Boolean |
| `fetch` | `fetch(action)` | The tool Hash. Raises `KeyError` if not exposed. |
| `actions` | `actions` | `Array<String>` |

Each tool Hash has `"name"`, `"action"`, `"capability"`, `"title"`, `"description"`, `"inputSchema"`, `"annotations"` (`readOnlyHint`, `consequentialHint`) and `"mutating"`.

Source: `portage-ucp-webmcp/lib/portage/ucp/webmcp/tool_catalog.rb`

### Rack::App

`Rack::App.new(catalog:, script_path: "/webmcp.js", call_path: "/webmcp", call_options: {}, registrar_options: {})` is one mountable Rack app. `GET <mount>/webmcp.js` serves the page script. `POST <mount>/webmcp` handles tool calls. Anything else returns a 404 JSON body.

- `call_options` go to `Rack::CallEndpoint.new(catalog:, allowed_origins: nil, require_origin: true, trusted_proxies: [], forwarded_host_allowed: [], passthrough_headers: [], passthrough_forwarded: "drop", max_body_bytes:, call_timeout:)`. Body limit default is 1,048,576 bytes and call timeout 30 seconds. The endpoint accepts only JSON POSTs, requires an allowed `Origin`, and serves only `tools/call` and `tools/list` for exposed actions.
- `registrar_options` go to `Registrar.new`: `endpoint:`, `credentials:`, `headers:`, `exposed_to:`, `include_polyfill:`, `reregister_wait_ms:`.

`Registrar.new(catalog:, endpoint:, credentials: "same-origin", headers: {}, exposed_to: nil, include_polyfill: false, reregister_wait_ms: nil)` renders the page script. `#to_js` returns the script and `#config` its settings Hash. `credentials` must be `"same-origin"`, `"include"` or `"omit"`, else `ArgumentError`. `Rack::ScriptEndpoint.new(registrar:)` serves it on GET and HEAD.

Source: `portage-ucp-webmcp/lib/portage/ucp/webmcp/rack/app.rb`, `portage-ucp-webmcp/lib/portage/ucp/webmcp/rack/call_endpoint.rb`, `portage-ucp-webmcp/lib/portage/ucp/webmcp/rack/script_endpoint.rb`, `portage-ucp-webmcp/lib/portage/ucp/webmcp/rack/request_limits.rb`, `portage-ucp-webmcp/lib/portage/ucp/webmcp/registrar.rb`

## End to end

Merchant side, in `config.ru`:

```ruby
require "portage/ucp/webmcp"

catalog = Portage::Ucp::WebMcp::ToolCatalog.new(adapter: adapter, authenticator: MyCookieAuthenticator.new)
map("/ucp") { run Portage::Ucp::WebMcp::Rack::App.new(catalog: catalog) }
# In your layout: <script src="/ucp/webmcp.js" defer></script>
```

Agent side, with Ferrum (inject `W.polyfill_js` with your driver before navigation if the browser has no native WebMCP):

```ruby
require "ferrum"
require "portage/ucp/webmcp"

W = Portage::Ucp::WebMcp
browser = Ferrum::Browser.new(headless: false)
browser.go_to("https://shop.example")

bridge = W::Bridges::ScriptEvaluator.ferrum(browser.page, headless: false)
session = W.connect(bridge: bridge)
session.search_catalog(query: "mug")

# On a page with unknown tool names, propose a mapping and confirm it before use:
proposal = W::Matcher.propose(bridge.list_tools)
# ... show `proposal` to the shopper, then:
session = W.connect(bridge: bridge, tool_names: W::Matcher.tool_names(proposal))
```

For the client session API, see [portage-ucp-client](portage-ucp-client.md).
