# portage-ucp

Protocol-only core gem: expose a commerce backend to AI shopping agents over **MCP**
([Model Context Protocol](https://modelcontextprotocol.io)) and **UCP**
([Universal Commerce Protocol](https://ucp.dev)) at once. Zero commerce-backend
dependencies — works with any backend that implements `Adapter`, Shopify or
otherwise. Adapter gems (`portage-ucp-shopify`, `portage-ucp-wix`, ...) are
consumers of this gem, not dependencies of it.

See the [root README](https://github.com/tomtom87/Portage#readme) for the full
walkthrough (an agent discovering a manifest and buying a snowboard end to end),
security model, and adapter comparison table. This README covers just what lives
in this gem.

## What it ships

| Class | Role |
|---|---|
| `Portage::Ucp::Adapter` | The contract your backend implements — override only the catalog/cart/checkout/order/identity methods you support; the rest stay unadvertised. |
| `Portage::Ucp::CapabilityRegistry` | Figures out which capabilities an `Adapter` actually backs. |
| `Portage::Ucp::Dispatcher` | Routes a capability+action call to the right `Adapter` method. |
| `Portage::Ucp::Mcp::Server` | Wraps an `Adapter` as an MCP server — one `MCP::Tool` per advertised action, stdio or Streamable HTTP. |
| `Portage::Ucp::Manifest` | Builds the signed `/.well-known/ucp` discovery document. |
| `Portage::Ucp::Rack::ManifestEndpoint` | Serves that manifest over Rack. |
| `Portage::Ucp::Rack::WebhookEndpoint` | HMAC-verified inbound order-lifecycle webhooks. |
| `Portage::Ucp::SchemaValidator` | Validates data against UCP's own vendored JSON Schemas/OpenRPC docs, offline. |
| `Portage::Ucp::Resolver` / `exe/portage-ucp-check` | Probes any store's homepage/`.well-known/ucp` and recommends the matching adapter gem. |

Security defaults are all locked down, not permissive-by-omission —
`UnconfiguredAuthenticator` rejects every mutating call until you configure a real
one, `PaymentTokenGuard` rejects raw card numbers before they reach your `Adapter`,
and manifest signing is opt-in. Full detail in the root README's
[Security hooks](https://github.com/tomtom87/Portage#security-hooks--nothing-is-permissive-by-default)
section.

## Installation

```ruby
# Gemfile
gem "portage-ucp"
```

```bash
bundle install
```

## Quickstart

```ruby
require "portage/ucp"

class MyAdapter < Portage::Ucp::Adapter
  def search_catalog(query:, limit:) = ...
  def get_product(product_id:) = ...
  def create_cart(line_items:, idempotency_key:) = ...
  # override only the capabilities you support
end

Portage::Ucp.configure do |config|
  config.authenticator = MyAuthenticator.new
  config.rate_limiter = MyRateLimiter.new
  config.business = { name: "Your Store", url: "https://your-shop.example" }
end

server = Portage::Ucp::Mcp::Server.build(adapter: MyAdapter.new)
server.start
```

See the root README's [Quickstart](https://github.com/tomtom87/Portage#quickstart)
and [Detailed walkthrough](https://github.com/tomtom87/Portage#detailed-walkthrough-an-agent-buys-a-snowboard)
for the full agent-side conversation, manifest/webhook Rack mounting, and a real
adapter to model your own against.

## Checking any store

```bash
bundle exec portage-ucp-check your-shop.example
```

Tries `/.well-known/ucp` first; falls back to platform detection and names the
matching `portage-ucp-<adapter>` gem, live-probing it if credentials are already in
env. See the root README's [Checking any store](https://github.com/tomtom87/Portage#checking-any-store)
section for sample output.

## Development

```bash
bundle exec rspec
bundle exec rubocop
```

See [`PLAN.md`](https://github.com/tomtom87/Portage/blob/main/PLAN.md) for the
design rationale and decision history behind this project.

## License

[MIT](LICENSE) — Copyright (c) 2026 Tom Whitbread.
