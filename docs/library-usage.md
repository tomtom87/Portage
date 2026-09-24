# Library usage

## Installation

```ruby
# Gemfile
gem "portage-ucp"
gem "portage-ucp-shopify" # or another adapter gem, or your own Adapter subclass
```

```bash
bundle install
```

## Usage

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
MCP::Server::Transports::StdioTransport.new(server).open # stdio; or mount as Streamable HTTP per the `mcp` gem's own docs
```

That's a running MCP server, wired up inline. Every adapter gem also ships an
executable that does steps 1 and 3 for you, so you don't need a throwaway Ruby file
just to point an MCP client (Claude Desktop, etc.) at a `command`
(Etsy and Instagram gain this `exe/` + `examples/` once `feat/etsy-exe` and
`harden/instagram` merge — see the [feature matrix](adapters/feature-matrix.md) for
current status):

```bash
bundle exec portage-ucp-shopify   # stdio, reads SHOPIFY_SHOP_DOMAIN /
                                   # SHOPIFY_ADMIN_ACCESS_TOKEN / SHOPIFY_STOREFRONT_ACCESS_TOKEN
```

Step 2 (wiring a real `authenticator`/`rate_limiter`/`business`) still has to come from
you — the exe won't guess those — so point `PORTAGE_UCP_CONFIG` at a Ruby file that
calls `Portage::Ucp.configure`, the same `-r`-a-file pattern `rackup`/Sidekiq use.
`portage-ucp-shopify/examples/portage_ucp.rb` is a copy-paste starting point
(bearer-token authenticator, in-process rate limiter):

```bash
PORTAGE_UCP_CONFIG=./config/portage_ucp.rb bundle exec portage-ucp-shopify
```

Without it, the server still starts but rejects every mutating call — the
`UnconfiguredAuthenticator` default from [Security hooks](security-hooks.md).

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

Five tool calls, one snowboard bought. [The walkthrough](walkthrough.md) shows what's actually running behind each of those — auth checks, PAN rejection, idempotent retries — plus how to serve the discovery manifest and order webhooks, from the shopper agent's side.
