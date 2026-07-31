# Portage::Ucp

![status: pre-release](https://img.shields.io/badge/status-pre--release%20(0.1.0)-orange)
![ruby](https://img.shields.io/badge/ruby-%3E%3D%203.2-red)
![license](https://img.shields.io/badge/license-MIT-blue)

Ruby gems that expose a commerce backend to AI shopping agents over **MCP** ([Model Context Protocol](https://modelcontextprotocol.io)) and **UCP** ([Universal Commerce Protocol](https://ucp.dev)) at once. Open-source, for any Ruby app on any e-commerce stack — not tied to any one merchant's business logic.

> **Status**: pre-release, `0.1.0`, not yet published to RubyGems. APIs may still shift before `1.0` — see [`PLAN.md`](PLAN.md) for the design log. Pin a git ref, not a version constraint, until then.

"Portage" — carrying cargo overland between waterways it can't sail directly between — is what this does: carries commerce operations across platforms that don't natively speak UCP or speak to each other.

Eight gems, mirroring how Faraday/Devise split core-vs-adapter:

| Gem | Role |
|---|---|
| [`portage-ucp`](portage-ucp/) | Protocol-only core: `Adapter` contract, capability registry, manifest builder, MCP server wrapper. Zero commerce-backend deps — works with any backend that implements `Adapter`, Shopify or otherwise. |
| [`portage-ucp-shopify`](portage-ucp-shopify/) | Shopify adapter — implements `Adapter` against Shopify's Admin + Storefront GraphQL APIs. One consumer of the core gem, not a dependency of it. |
| [`portage-ucp-wix`](portage-ucp-wix/) | Wix adapter — implements `Adapter` against Wix's Stores Catalog and eCommerce REST APIs. |
| [`portage-ucp-woocommerce`](portage-ucp-woocommerce/) | WooCommerce adapter — implements `Adapter` against a WooCommerce site's Admin REST API and Store API. |
| [`portage-ucp-bigcommerce`](portage-ucp-bigcommerce/) | BigCommerce adapter — implements `Adapter` against a BigCommerce store's v3 Catalog/Carts/Checkouts APIs and v2 Orders API. |
| [`portage-ucp-magento`](portage-ucp-magento/) | Magento/Adobe Commerce adapter — implements `Adapter` against a Magento site's REST v1 API (admin-token catalog/order, anonymous guest-cart cart/checkout). |
| [`portage-ucp-etsy`](portage-ucp-etsy/) | Etsy adapter — real catalog/order against Etsy's Open API v3; checkout is redirect-link only (Etsy's public API has no cart/checkout endpoint). |
| [`portage-ucp-instagram`](portage-ucp-instagram/) | Instagram/Facebook Shops adapter — real catalog against Meta's Graph API Commerce Catalog; checkout is redirect-link only, and order lookup only works for "checkout on Instagram/Facebook" merchants. |

A backend on some other stack (a hand-rolled Rails store, another platform entirely) writes its own thin `Adapter` subclass against `portage-ucp` directly — the adapters above are just the ones that exist today, used for the examples below because Shopify's is the most complete. Not every backend has a real cart/checkout API to back — Etsy and Instagram/Facebook Shops don't, so those two adapters only implement catalog/order for real and fall back to a redirect-link `Checkout` instead of a full transactional one (see their READMEs).

**Already on Shopify and wondering why you'd need this at all** — Shopify ships its own native Universal Commerce Agent app that auto-serves `/.well-known/ucp` with checkout+order capabilities, no code required. This gem is for the gap that app leaves: `cart`/`catalog` capabilities it doesn't advertise, a signed manifest it can't produce, and a self-hosted setup for backends other than Shopify. Full comparison in [Why `/.well-known/ucp`?](#why-wellknownucp).

## Contents

- [Quickstart](#quickstart)
- [Security hooks](#security-hooks--nothing-is-permissive-by-default)
- [Detailed walkthrough: an agent buys a snowboard](#detailed-walkthrough-an-agent-buys-a-snowboard)
- [Why `/.well-known/ucp`?](#why-wellknownucp)
- [How the pieces fit together](#how-the-pieces-fit-together)
- [Writing your own adapter](#writing-your-own-adapter)
- [Spec conformance](#spec-conformance)
- [Development](#development)
- [Requirements](#requirements)
- [Contributing](#contributing)
- [License](#license)

## Requirements

- Ruby >= 3.2
- `mcp` gem `~> 0.24` (pulled in by `portage-ucp`)
- For `portage-ucp-shopify`: a Shopify Admin API access token, a Storefront API access token, or both — each capability family works independently if you only have one.
- For `portage-ucp-wix`: a Wix app client_id/client_secret plus the target site's instance_id, exchanged for a site-scoped access token.
- For `portage-ucp-woocommerce`: a WooCommerce Admin REST API consumer key/secret pair (static, generated in wp-admin) — no token exchange needed.
- For `portage-ucp-bigcommerce`: a BigCommerce API account client_id/access_token pair (static, generated in the control panel) plus your store hash — no token exchange needed.
- For `portage-ucp-magento`: a Magento admin bearer token, exchanged from username/password — plus a `default_address:` and payment method id if you'll call `complete_checkout` (see that gem's README for why).
- For `portage-ucp-etsy`: an Etsy OAuth access_token (from shop-owner consent) plus your app's `x-api-key` — catalog/order only, checkout is redirect-link (see that gem's README for why).
- For `portage-ucp-instagram`: a Meta Graph API long-lived access token plus your Commerce Catalog id — catalog only, checkout is redirect-link and order lookup only works for "checkout on Instagram/Facebook" merchants (see that gem's README for why).

## Quickstart

```ruby
# Gemfile
gem "portage-ucp"
gem "portage-ucp-shopify" # or your own Adapter subclass
```

```ruby
require "portage/ucp"
require "portage/ucp/shopify"

# 1. build an adapter
client = Portage::Ucp::Shopify::Client.new(
  shop_domain: "your-shop.myshopify.com",
  admin_access_token: ENV.fetch("SHOPIFY_ADMIN_ACCESS_TOKEN"),
  storefront_access_token: ENV.fetch("SHOPIFY_STOREFRONT_ACCESS_TOKEN")
)
adapter = Portage::Ucp::Shopify::Adapter.new(client: client)

# 2. configure defaults (once, e.g. in an initializer) — see "Security hooks" below,
#    the unconfigured defaults reject every mutating call on purpose
Portage::Ucp.configure do |config|
  config.authenticator = MyAuthenticator.new
  config.rate_limiter = MyRateLimiter.new
  config.business = { name: "Your Store", url: "https://your-shop.example" }
end

# 3. serve it over MCP
server = Portage::Ucp::Mcp::Server.build(adapter: adapter)
server.start # stdio, or mount as Streamable HTTP per the `mcp` gem's own docs
```

That's a running MCP server, wired up inline. `portage-ucp-shopify` also ships an
executable that does steps 1 and 3 for you, so you don't need a throwaway Ruby file
just to point an MCP client (Claude Desktop, etc.) at a `command`:

```bash
bundle exec portage-ucp-shopify   # stdio, reads SHOPIFY_SHOP_DOMAIN /
                                   # SHOPIFY_ADMIN_ACCESS_TOKEN / SHOPIFY_STOREFRONT_ACCESS_TOKEN
```

Step 2 (wiring a real `authenticator`/`rate_limiter`/`business`) still has to come from
you — the exe won't guess those — so point `PORTAGE_UCP_CONFIG` at a Ruby file that
calls `Portage::Ucp.configure`, the same `-r`-a-file pattern `rackup`/Sidekiq use.
[`portage-ucp-shopify/examples/portage_ucp.rb`](portage-ucp-shopify/examples/portage_ucp.rb)
is a copy-paste starting point (bearer-token authenticator, in-process rate limiter):

```bash
PORTAGE_UCP_CONFIG=./config/portage_ucp.rb bundle exec portage-ucp-shopify
```

Without it, the server still starts but rejects every mutating call — the
`UnconfiguredAuthenticator` default from [Security hooks](#security-hooks--nothing-is-permissive-by-default) below.

Every adapter gem ships the same executable, `examples/portage_ucp.rb` starting point, and `PORTAGE_UCP_CONFIG` hook — just point `bundle exec` at the one matching your backend and fill in its env vars:

| Gem | Executable | Required env vars |
|---|---|---|
| `portage-ucp-shopify` | `portage-ucp-shopify` | `SHOPIFY_SHOP_DOMAIN`, `SHOPIFY_ADMIN_ACCESS_TOKEN` and/or `SHOPIFY_STOREFRONT_ACCESS_TOKEN` |
| `portage-ucp-wix` | `portage-ucp-wix` | `WIX_ACCESS_TOKEN` |
| `portage-ucp-woocommerce` | `portage-ucp-woocommerce` | `WOOCOMMERCE_SITE_URL`, `WOOCOMMERCE_CONSUMER_KEY`, `WOOCOMMERCE_CONSUMER_SECRET`; optional `WOOCOMMERCE_CURRENCY` (default `USD`), `WOOCOMMERCE_PAYMENT_METHOD` (for `complete_checkout`) |
| `portage-ucp-bigcommerce` | `portage-ucp-bigcommerce` | `BIGCOMMERCE_STORE_HASH`, `BIGCOMMERCE_CLIENT_ID`, `BIGCOMMERCE_ACCESS_TOKEN`, `BIGCOMMERCE_SITE_URL`; optional `BIGCOMMERCE_CURRENCY` (default `USD`), `BIGCOMMERCE_PAYMENT_GATEWAY_ID` (for `complete_checkout`) |
| `portage-ucp-magento` | `portage-ucp-magento` | `MAGENTO_BASE_URL`, `MAGENTO_ADMIN_TOKEN`; optional `MAGENTO_CURRENCY` (default `USD`), `MAGENTO_SITE_URL`, `MAGENTO_PAYMENT_METHOD`/`MAGENTO_DEFAULT_ADDRESS` (a JSON object, for `complete_checkout`) |

An agent connecting to it can now do this end to end — shown here as simplified `tools/call name { args }` shorthand, not the literal JSON-RPC envelope on the wire:

```
tools/call search_catalog { query: "snowboard", limit: 5 }
  → Powder Chaser 158cm, $549.00, gid://shopify/Product/1

tools/call get_product { product_id: "gid://shopify/Product/1" }
  → variant gid://shopify/ProductVariant/11, "158cm", available

tools/call create_checkout { line_items: [{ product_id: "gid://shopify/ProductVariant/11", quantity: 1 }],
                             idempotency_key: "b3f1-..." }
  → checkout gid://shopify/Cart/abc, status: incomplete

tools/call complete_checkout { checkout_id: "gid://shopify/Cart/abc", payment_token: "spt_1a2b3c...",
                               idempotency_key: "b3f1-..." }
  → status: completed

tools/call get_order { order_id: "gid://shopify/Order/9001" }
  → checkout_id: gid://shopify/Cart/abc, permalink_url: https://your-shop.example/orders/9001, totals: [...]
```

Five tool calls, one snowboard bought. The [detailed walkthrough](#detailed-walkthrough-an-agent-buys-a-snowboard) below shows what's actually running behind each of those — auth checks, PAN rejection, idempotent retries — plus how to serve the discovery manifest and order webhooks.

## Security hooks — nothing is permissive by default

Read this before wiring a server up to anything real — every default here is deliberately locked down, not permissive-by-omission:

- **Authentication**: `Portage::Ucp::UnconfiguredAuthenticator` (the default) rejects every mutating call until you configure a real one. Implement `#call(server_context)` to return a truthy auth context, or raise `Portage::Ucp::AuthenticationError`.
- **Rate limiting**: `Portage::Ucp::NullRateLimiter` (the default) never limits. Implement `#check!(key, capability)` and raise `Portage::Ucp::RateLimitExceededError` to block a call.
- **PAN guard**: `Portage::Ucp::PaymentTokenGuard` rejects any `payment_token` that looks like a raw card number (digits-only, Luhn-valid, 12–19 chars) before it ever reaches your `Adapter` — `complete_checkout` must receive a tokenized credential.
- **Idempotency**: every mutating capability action takes an `idempotency_key:` — your `Adapter` is responsible for deduping retries (see `portage-ucp-shopify`'s in-process dedup table for one approach).
- **Observability**: `Portage::Ucp::Observability.log` emits structured JSON log events through a consumer-injected logger, redacting `payment_token`/`oauth_token`/`authorization` automatically.
- **Manifest signing**: `Portage::Ucp::Manifest` never generates or stores keys — pass a `signer` (anything responding to `#kid` and `#sign(canonical_json)`) to produce a signed manifest; omit it to serve unsigned.

## Detailed walkthrough: an agent buys a snowboard

A shopper tells their AI agent: *"Find me a snowboard under $600 and buy it."* The agent already discovered your store's manifest at `/.well-known/ucp`, saw `dev.ucp.shopping.catalog`/`cart`/`checkout` advertised, and connects over MCP. Here's the actual tool-call sequence hitting your server, and what runs behind each call.

**1. Agent searches the catalog**

```
tools/call search_catalog { "query": "snowboard", "limit": 5 }
```

```ruby
adapter.search_catalog(query: "snowboard", limit: 5)
# => [#<Portage::Ucp::Product id: "gid://shopify/Product/1", title: "Powder Chaser 158cm",
#      price: #<Money amount_minor: 54900, currency: "USD">, available: true, ...>, ...]
```

**2. Agent pulls full detail on the one that fits the budget**

```
tools/call get_product { "product_id": "gid://shopify/Product/1" }
```

```ruby
adapter.get_product(product_id: "gid://shopify/Product/1")
# => variants: [{ id: "gid://shopify/ProductVariant/11", title: "158cm", available: true, price: ... }]
```

**3. Agent creates a checkout for the variant it picked**

```
tools/call create_checkout {
  "line_items": [{ "product_id": "gid://shopify/ProductVariant/11", "quantity": 1 }],
  "idempotency_key": "b3f1-..."
}
```

Before this runs, the framework checks `Authenticator#call` (does this session own an authorized payment context?) and `RateLimiter#check!` — reject either and the agent gets an MCP error response instead of ever reaching your `Adapter`.

```ruby
adapter.create_checkout(line_items: [{ product_id: "gid://shopify/ProductVariant/11", quantity: 1 }],
                        idempotency_key: "b3f1-...")
# => #<Checkout id: "gid://shopify/Cart/abc", status: "incomplete", totals: [...], ...>
```

**4. Agent completes checkout with a tokenized payment credential**

The agent never handles a raw card number — it exchanges the shopper's payment method with a payment handler first and gets back a single-use token.

```
tools/call complete_checkout {
  "checkout_id": "gid://shopify/Cart/abc",
  "payment_token": "spt_1a2b3c...",
  "idempotency_key": "b3f1-..."
}
```

`Portage::Ucp::PaymentTokenGuard` runs first — if `payment_token` looked like a raw PAN instead of an opaque token, this raises before your `Adapter` ever sees it.

```ruby
adapter.complete_checkout(checkout_id: "gid://shopify/Cart/abc", payment_token: "spt_1a2b3c...",
                          idempotency_key: "b3f1-...")
# => #<Checkout id: "gid://shopify/Cart/abc", status: "completed", ...>
```

Reusing the same `idempotency_key` on a retry (dropped connection, agent double-submit) replays the cached result instead of charging twice.

**5. Agent (or your own order-sync webhook) fetches the resulting order**

```
tools/call get_order { "order_id": "gid://shopify/Order/9001" }
```

```ruby
adapter.get_order(order_id: "gid://shopify/Order/9001")
# => #<Order id: ..., checkout_id: "gid://shopify/Cart/abc", permalink_url: "https://your-shop.example/...",
#      fulfillment: { "expectations" => [...], "events" => [] }, totals: [...] >
```

Meanwhile `Portage::Ucp::Rack::WebhookEndpoint` receives Shopify's fulfillment updates independently and calls your `on_order_event` callback as tracking events land — the shopper's agent can poll `get_order` again later to answer "where's my snowboard?" without you building that plumbing yourself.

### Serving the discovery manifest and webhooks

The tool calls above only happen because the agent found your manifest first. Serve it (and inbound order webhooks) over Rack:

```ruby
# config.ru
manifest = Portage::Ucp::Manifest.new(adapter: adapter)

map "/.well-known/ucp" do
  run Portage::Ucp::Rack::ManifestEndpoint.new(manifest: manifest)
end

map "/webhooks/ucp/orders" do
  run Portage::Ucp::Rack::WebhookEndpoint.new(
    secret: ENV.fetch("UCP_WEBHOOK_SECRET"),
    on_order_event: ->(order) { MyOrderSync.call(order) }
  )
end
```

`ManifestEndpoint` refuses to serve payment-handler declarations over plaintext HTTP (set `allow_insecure: true` for local dev only). `WebhookEndpoint` verifies an HMAC-SHA256 signature against the raw body before parsing anything.

## Why `/.well-known/ucp`?

`/.well-known/<name>` is [RFC 8615](https://www.rfc-editor.org/rfc/rfc8615)'s standard location for site-wide metadata a client should be able to find without any prior coordination — no custom DNS record, no per-integration config, just a fixed, predictable path any crawler or agent already knows to check. It's the same slot `/.well-known/security.txt` and `/.well-known/openid-configuration` use. UCP reuses it for the same reason: an agent that has never talked to your store before can hit `https://your-shop.example/.well-known/ucp` cold and get back capabilities, payment handlers, and signing keys.

It sits alongside, not in place of, [`llms.txt`](https://llmstxt.org) — a related-but-different convention some sites use to hand an LLM a curated, human-readable index of pages worth reading (docs, key content) in place of scraping raw HTML. `llms.txt` describes *content* for an LLM to read; `/.well-known/ucp` describes *capabilities* an agent can call. A store could reasonably serve both.

`llms.txt` is normally its own plain file at the site root (`/llms.txt`, markdown):

```markdown
# Your Store

> Online retailer of snowboards and winter gear.

## Docs
- [Shipping policy](/pages/shipping): rates, timelines, international.
- [Size guide](/pages/size-guide): board length by rider weight/height.

## Optional
- [Blog](/blog): buying guides and gear reviews.
```

...but it doesn't have to live at that exact path — some sites instead point to it from HTML `<head>`, the same discovery pattern as `rel="sitemap"` or `rel="alternate"`:

```html
<link rel="llms.txt" href="/docs/llms.txt">
```

That lets an agent already parsing your page's `<head>` find the file without guessing the root path — useful if it lives somewhere other than `/llms.txt`, or you want it scoped per-section (e.g. `/blog/llms.txt` linked only from blog pages).

Shopify stores get a default `/llms.txt` generated automatically for the storefront (product/collection/page links, no merchant config needed) — same "don't reimplement what the platform already ships" reasoning as its native Universal Commerce Agent app for `/.well-known/ucp` (see PLAN.md §1). This gem's Shopify adapter targets the gap: catalog/cart/checkout/order over UCP+MCP, which the default `llms.txt` doesn't cover.

**What Shopify serves at those paths by default**, with no merchant config, once its Universal Commerce Agent app is installed:

```
GET https://your-shop.myshopify.com/llms.txt
GET https://your-shop.myshopify.com/.well-known/ucp
```

```json
// GET /.well-known/ucp — Shopify's native manifest
{
  "ucp_version": "2026-01-23",
  "business": { "name": "Your Store" },
  "capabilities": [
    { "name": "dev.ucp.shopping.checkout", "version": "1" },
    { "name": "dev.ucp.shopping.order", "version": "1" }
  ],
  "payment_handlers": [],
  "signing_keys": []
}
```

Two gaps this leaves, both of which `Portage::Ucp::Manifest` closes: `signing_keys` is always empty — Shopify's app doesn't generate or hold keys, so an agent that verifies manifest authenticity (Google's do) treats it as unverified — and its `ucp_version` trails the spec this gem targets (`2026-04-08`). `dev.ucp.shopping.cart` and `dev.ucp.shopping.catalog` aren't advertised at all — that's the gap `portage-ucp-shopify`'s `Adapter` fills, on top of the same `/.well-known/ucp` path, just self-hosted and signed.

## How the pieces fit together

```
Your backend
    ↓ implements
Portage::Ucp::Adapter (catalog/cart/checkout/order/identity methods)
    ↓ registered against
Portage::Ucp::CapabilityRegistry  (which capabilities does this adapter actually support?)
    ↓ used by
Portage::Ucp::Dispatcher          (routes a capability+action call to the Adapter method)
    ↓ wrapped by
Portage::Ucp::Mcp::Server.build   (generates MCP::Tool objects, one per advertised action)
    ↓ served over
stdio / Streamable HTTP (via the `mcp` gem)

Portage::Ucp::Manifest             (builds the signed /.well-known/ucp discovery doc)
    ↓ served by
Portage::Ucp::Rack::ManifestEndpoint

Portage::Ucp::Rack::WebhookEndpoint (HMAC-verified inbound order-lifecycle webhooks)
```

A capability (e.g. `dev.ucp.shopping.cart`) is only advertised if your `Adapter` overrides at least one of its backing methods — an unconfigured method just means that capability doesn't show up in the manifest or the MCP tool list, not a 500.

## Writing your own adapter

```ruby
class MyAdapter < Portage::Ucp::Adapter
  def search_catalog(query:, limit:) = ...
  def get_product(product_id:) = ...
  def create_cart(line_items:, idempotency_key:) = ...
  # override only the capabilities you support — the rest stay unadvertised
end
```

See `Portage::Ucp::Adapter` for the full method contract (catalog, cart, checkout, order, identity linking) and `portage-ucp-shopify`'s `Adapter` for a complete real implementation to model against.

## Spec conformance

`Portage::Ucp::SchemaValidator` validates data against UCP's own vendored JSON Schemas/OpenRPC docs offline (no network calls, no reliance on ucpchecker.com as a CI gate) — useful in your own test suite if you want to assert your adapter's output is schema-conformant beyond what `to_wire_h` already guarantees.

## Development

Each gem manages its own tests/lint independently — its own `Gemfile`/`Gemfile.lock`, own `spec/`, no shared state or run-order dependency between gems:

```bash
cd portage-ucp && bundle exec rspec && bundle exec rubocop
cd portage-ucp-shopify && bundle exec rspec && bundle exec rubocop
cd portage-ucp-wix && bundle exec rspec && bundle exec rubocop
cd portage-ucp-woocommerce && bundle exec rspec && bundle exec rubocop
cd portage-ucp-bigcommerce && bundle exec rspec && bundle exec rubocop
cd portage-ucp-magento && bundle exec rspec && bundle exec rubocop
cd portage-ucp-etsy && bundle exec rspec && bundle exec rubocop
cd portage-ucp-instagram && bundle exec rspec && bundle exec rubocop
```

Or run the full suite across every gem in one command, via the root `Rakefile` — it just shells into each gem dir in turn and stops at the first failure, no root-level bundle or cross-gem dependency involved:

```bash
rake spec   # == rake, spec is the default task
```

See [`PLAN.md`](PLAN.md) for the design rationale and decision history behind this project.

## Contributing

Bug reports and pull requests welcome. Since this is pre-`1.0` and still spec-tracking (`PLAN.md` is the living design log), open an issue to discuss any change bigger than a bugfix before sending a PR — the capability/adapter contract is still settling.

## License

[MIT](LICENSE) — Copyright (c) 2026 Tom Whitbread.
