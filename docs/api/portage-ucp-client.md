# portage-ucp-client API

`portage-ucp-client` (0.6.3) is the buyer side of UCP: use it when your Ruby shopping agent needs to discover a store, or drive its own `Adapter`, and place an order through one `Session` object.

Require it after the core gem. The core gem's API is on [portage-ucp](portage-ucp.md).

```ruby
require "portage/ucp"
require "portage/ucp/client"
```

## Entry points

All entry points are module functions on `Portage::Ucp::Client`. Each returns a `Session`.

| Method | Signature | Returns | Notes |
|---|---|---|---|
| `for_adapter` | `Client.for_adapter(adapter, **server_opts)` | `Session` | Loopback. Wraps an `Adapter` in-process. `server_opts` go to `Portage::Ucp::Mcp::Server.build` (for example `authenticator:`, `rate_limiter:`, `journal:`). |
| `connect` | `Client.connect(command: nil, args: [], env: nil, url: nil, headers: {}, capabilities: nil, proxy: nil)` | `Session` | Stdio if `command:` is given, else Streamable HTTP if `url:` is given. Raises `ArgumentError` if neither. `headers:` and `proxy:` only apply to `url:`. |
| `discover` | `Client.discover(url, headers: {}, proxy: nil)` | `Session` | GETs `<url>/.well-known/ucp`, picks the `mcp` service endpoint, connects over HTTP. The session's `capabilities` come from the manifest. |
| `with_user_agent` | `Client.with_user_agent(headers)` | `Hash` | Returns `headers` unchanged if it already names a `User-Agent` (any case). Otherwise adds `USER_AGENT`. |

`fetch_manifest` is a private class method. You cannot call it. Use `discover`.

Constants: `Client::MANIFEST_PATH` is `"/.well-known/ucp"`. `Client::USER_AGENT` is `"portage-ucp-client/<VERSION> (+https://github.com/tomtom87/Portage)"`. It is sent on the manifest GET and on every HTTP call unless your `headers:` name one.

Source: `portage-ucp-client/lib/portage/ucp/client.rb`, `portage-ucp-client/lib/portage/ucp/client/version.rb`

### Manifest handling

`discover` accepts two manifest shapes. Live UCP manifests nest everything under a `"ucp"` key. Portage's own server side emits a flat shape. Both work.

- `services` may be a Hash of arrays or an Array. The client keeps entries whose `transport` is `"mcp"`, picks the highest `version` string, and uses its `endpoint`.
- `capabilities` may be a Hash (keys are used) or an Array of objects (each `name` is used).

```ruby
session = Portage::Ucp::Client.discover(
  "https://shop.example",
  headers: { "User-Agent" => "my-agent/1.0" },
  proxy: "http://proxy.internal:3128"
)
session.advertises?("dev.ucp.shopping.checkout") # => true, false or nil
```

The `proxy:` option is passed to the HTTP connection that `discover` opens. The manifest GET itself uses `Net::HTTP.get_response` and does not receive `proxy:`. `headers:` go to both.

Source: `portage-ucp-client/lib/portage/ucp/client.rb`

## Transports

You do not build these directly in normal use. They are public constants under `Portage::Ucp::Client::Transports`, and every one exposes `call_tool(name:, arguments:, meta: nil)`.

| Transport | Constructor | Reached by | Notes |
|---|---|---|---|
| `Loopback` | `Loopback.new(adapter:, **server_opts)` | `Client.for_adapter` | Builds `Portage::Ucp::Mcp::Server` from the adapter and calls it in-process. Runs the real authenticator, rate limiter and `Dispatcher`. Results have symbol keys. |
| `Stdio` | `Stdio.new(command:, args: [], env: nil)` | `Client.connect(command:)` | Spawns a subprocess speaking JSON-RPC on stdin/stdout, through the `mcp` gem's client. Does the `initialize` handshake in the constructor. Results have string keys. |
| `Http` | `Http.new(url:, headers: {}, proxy: nil)` | `Client.connect(url:)`, `Client.discover` | Streamable HTTP through the `mcp` gem's client. Handshake in the constructor. Reshapes flat arguments into the real UCP wire format. Results have string keys. |

Stdio and Loopback drop the arguments `context`, `handler_id` and `credential_type`. They also drop `cart_id` on `create_checkout` only (on cart calls `cart_id` is a real argument and is kept). Only HTTP uses these.

Custom transports work too: `Session.new(transport:)` takes any object with `call_tool(name:, arguments:, meta: nil)`. The WebMCP gem does this. See [portage-ucp-webmcp](portage-ucp-webmcp.md).

Source: `portage-ucp-client/lib/portage/ucp/client/transports/loopback.rb`, `portage-ucp-client/lib/portage/ucp/client/transports/stdio.rb`, `portage-ucp-client/lib/portage/ucp/client/transports/http.rb`, `portage-ucp-client/lib/portage/ucp/client/transports/local_arguments.rb`, `portage-ucp-client/lib/portage/ucp/client/transports/ucp_wire_shape.rb`

## Session

`Portage::Ucp::Client::Session` has the same convenience methods as the merchant-side `Adapter`, whatever transport is underneath. There is no public generic `call_tool` or tool-listing method on `Session`. Each method below maps to one tool.

Every method returns the tool's `structuredContent`. That is `nil` if the server sent none. It is a string-keyed Hash over stdio and HTTP and symbol-keyed over loopback. A tool that reports `isError: true` raises `ServerError` instead.

Every method takes `meta:` (default `nil`). Over HTTP it must be `{ agent_profile: "<url>" }`. See "Agent profile" below.

| Method | Signature | Notes |
|---|---|---|
| `initialize` | `Session.new(transport:, capabilities: nil)` | `capabilities` is an Array of reverse-domain names, or nil if unknown. |
| `capabilities` | `session.capabilities` | Reader. Populated by `discover`. nil after `for_adapter` and `connect` unless you pass `capabilities:`. |
| `advertises?` | `advertises?(capability_name)` | `true` or `false`. `nil` if capabilities are unknown. Attempt the call when nil. |
| `search_catalog` | `search_catalog(query:, limit: 20, context: nil, meta: nil)` | |
| `get_product` | `get_product(product_id:, context: nil, meta: nil)` | |
| `lookup_catalog` | `lookup_catalog(product_ids:, context: nil, meta: nil)` | |
| `get_cart` | `get_cart(cart_id:, meta: nil)` | |
| `create_cart` | `create_cart(line_items:, idempotency_key: nil, context: nil, meta: nil)` | Mutating. |
| `update_cart` | `update_cart(cart_id:, line_items:, idempotency_key: nil, context: nil, meta: nil)` | Mutating. |
| `cancel_cart` | `cancel_cart(cart_id:, idempotency_key: nil, meta: nil)` | Mutating. |
| `create_checkout` | `create_checkout(line_items:, idempotency_key: nil, fulfillment: nil, cart_id: nil, context: nil, meta: nil)` | Mutating. `cart_id:` converts a cart and is HTTP-only. `fulfillment:` is only exercised over loopback; leave it nil on stdio and HTTP. |
| `get_checkout` | `get_checkout(checkout_id:, meta: nil)` | |
| `update_checkout` | `update_checkout(checkout_id:, line_items:, idempotency_key: nil, fulfillment: nil, context: nil, meta: nil)` | Mutating. |
| `complete_checkout` | `complete_checkout(checkout_id:, payment_token:, idempotency_key: nil, handler_id: nil, credential_type: nil, meta: nil)` | Mutating. Runs `PaymentTokenGuard.validate!` first. `handler_id:` and `credential_type:` matter over HTTP only. |
| `cancel_checkout` | `cancel_checkout(checkout_id:, idempotency_key: nil, meta: nil)` | Mutating. |
| `get_order` | `get_order(order_id:, meta: nil)` | |
| `link_identity` | `link_identity(oauth_token:, meta: nil)` | Not in `MUTATING_ACTIONS`, so no idempotency key is added. |
| `create_payment_enrollment` | `create_payment_enrollment(idempotency_key: nil, meta: nil)` | Mutating. Portage extension. Check `advertises?` first. |
| `get_payment_enrollment` | `get_payment_enrollment(enrollment_id:, meta: nil)` | Portage extension. |

`line_items` is an Array of `{ product_id:, quantity: }` hashes.

`context:` is the UCP `context` object: `address_country`, `address_region`, `postal_code`, `currency`, `language`. It is optional on paper. Against a real store, leave it out and you can get an empty cart or prices in the wrong market. Send it on catalog and cart calls to real stores. Loopback and stdio ignore it.

Source: `portage-ucp-client/lib/portage/ucp/client/session.rb`, `portage-ucp-client/lib/portage/ucp/client/transports/ucp_wire_shape.rb`

## Agent profile

Real UCP servers fetch a profile URL to identify the calling agent. Pass it on every call as `meta: { agent_profile: url }`. String keys (`"agent_profile"`) also work.

```ruby
meta = { agent_profile: "https://example.com/agent-profile.json" }
session.search_catalog(query: "mug", meta: meta)
```

What each transport does with it:

- HTTP: sends it as `meta["ucp-agent"]["profile"]` inside the tool arguments. If it is missing, `Http#call_tool` raises `MissingAgentProfileError` before any request goes out.
- Loopback: copies it to `_meta["ucp-agent.profile"]`, which is where `Mcp::Server` reads it. Not required.
- Stdio: passes `meta` through as the MCP `_meta` field unchanged. Not required.

To host a profile, see [Agent profile](../agent-profile.md).

Source: `portage-ucp-client/lib/portage/ucp/client/transports/http.rb`, `portage-ucp-client/lib/portage/ucp/client/transports/loopback.rb`

## requires_escalation

A checkout or order with `status == "requires_escalation"` is returned as normal data. It is not raised. Your code must branch on it before calling `complete_checkout`. The `links` array holds where the shopper must go.

```ruby
checkout = session.create_checkout(line_items: items, meta: meta)
if checkout["status"] == "requires_escalation"
  puts "Shopper must act: #{checkout['links'].first['url']}"
else
  session.complete_checkout(checkout_id: checkout["id"], payment_token: token, meta: meta)
end
```

For a typed check, use `Portage::Ucp::Decision::EscalationPolicy` from [portage-ucp-decision](portage-ucp-decision.md).

Source: `portage-ucp-client/lib/portage/ucp/client/session.rb`

## Idempotency

`Session` adds `idempotency_key` (a `SecureRandom.uuid`) to every call whose action is in `Session::MUTATING_ACTIONS`, unless you pass one:

`create_cart update_cart cancel_cart create_checkout update_checkout complete_checkout cancel_checkout create_payment_enrollment`

Pass your own key when you retry a call, so the server replays the first result instead of acting twice. Over HTTP the key also goes out as `meta["idempotency-key"]`.

```ruby
key = SecureRandom.uuid
session.complete_checkout(checkout_id: id, payment_token: token, idempotency_key: key, meta: meta)
```

Source: `portage-ucp-client/lib/portage/ucp/client/session.rb`, `portage-ucp-client/lib/portage/ucp/client/transports/http.rb`

## Errors

All inherit from `Portage::Ucp::Client::Error < StandardError`.

| Class | Raised by | When |
|---|---|---|
| `DiscoveryError` | `Client.discover` | The manifest GET is not 2xx, the body is not JSON, or the host is unreachable (any other `StandardError`, message includes the class). Looks the same as "store does not run UCP". |
| `ManifestShapeError < DiscoveryError` | `Client.discover` | The manifest parsed but has no `mcp` service entry. The store does run UCP, so do not treat it like a 404. Rescue it before `DiscoveryError`. |
| `MissingAgentProfileError` | Http transport | Any HTTP call without `meta: { agent_profile: url }`. |
| `ServerError` | All transports | A tool result has `isError: true`. `#message` is the server's text. See below. |
| `PaymentPermissionError` | Http transport | `complete_checkout` is refused for lack of permission. Matched by message pattern `/forbidden\|not enabled\|not granted\|checkout.?completion/i`. Fall back to the checkout's `continue_url`. See [tool gating](../ucp-tool-gating-investigation.md). |
| `UnsupportedWireShapeError` | Http transport | `complete_checkout` with any `handler_id:` other than the card handler `"dev.shopify.card"`. |

Two more errors reach you from outside this gem:

- `Portage::Ucp::RawPanRejectedError` comes from `PaymentTokenGuard.validate!` in `complete_checkout`, before anything is sent. Pass a token, never a card number.
- `MCP::Client::RequestHandlerError` from the `mcp` gem can propagate from the HTTP transport (it is re-raised after the permission check).

`ServerError` has these members:

| Member | Returns |
|---|---|
| `payload` | The parsed JSON error document, or nil if the text was not a JSON object. |
| `server_messages` | Array of Hashes with `:code`, `:content`, `:severity` (nil values removed). Empty if no payload. |
| `summary` | The message contents joined with `"; "`, or the raw message when there are none. |
| `continue_url` | `payload["continue_url"]` or nil. Where the shopper can finish by hand. |

```ruby
begin
  session.create_cart(line_items: items, meta: meta)
rescue Portage::Ucp::Client::ServerError => e
  warn e.summary
  puts "Finish here: #{e.continue_url}" if e.continue_url
end
```

`Portage::Ucp::Client::ToolResult.extract(response, symbol_keys:)` is the shared normaliser. It returns `structuredContent` or raises `ServerError`. You only need it when writing a custom transport.

Source: `portage-ucp-client/lib/portage/ucp/client/errors.rb`, `portage-ucp-client/lib/portage/ucp/client/tool_result.rb`, `portage-ucp-client/lib/portage/ucp/client/transports/http/complete_checkout_wire_shape.rb`

## Proxy and Faraday

`proxy:` on `connect(url:)` and `discover` reaches the Faraday connection behind the `mcp` gem's HTTP client as `faraday.proxy = proxy`. A bare URL string is the usual value. Any value `Faraday::Connection#proxy=` accepts works. Per the source comments, Faraday also reads the standard proxy environment variables on its own. Stdio ignores `proxy:`.

Source: `portage-ucp-client/lib/portage/ucp/client/transports/http.rb`

## End to end

```ruby
require "portage/ucp"
require "portage/ucp/client"

meta = { agent_profile: "https://example.com/agent-profile.json" }
context = { address_country: "GB", currency: "GBP", language: "en" }

begin
  session = Portage::Ucp::Client.discover("https://shop.example")
rescue Portage::Ucp::Client::DiscoveryError => e
  abort "no UCP here: #{e.message}"
end

results = session.search_catalog(query: "mug", limit: 5, context: context, meta: meta)
product_id = "..." # pick from results; the result shape is the store's

checkout = session.create_checkout(
  line_items: [{ product_id: product_id, quantity: 1 }], context: context, meta: meta
)

if checkout["status"] == "requires_escalation"
  puts checkout["links"]
else
  session.complete_checkout(checkout_id: checkout["id"], payment_token: ENV.fetch("PAYMENT_TOKEN"), meta: meta)
end
```

For a runnable loopback version, see the [walkthrough](../walkthrough.md) and [library usage](../library-usage.md).
