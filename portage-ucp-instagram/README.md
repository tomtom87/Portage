# portage-ucp-instagram

Instagram/Facebook Shops adapter for [`portage-ucp`](../portage-ucp). Implements `Portage::Ucp::Adapter` against Meta's Graph API Commerce Catalog. Generic only — no merchant-specific business logic. Plain `Net::HTTP`, no Facebook SDK runtime dependency.

## What it covers — and what it deliberately doesn't

Like [`portage-ucp-etsy`](../portage-ucp-etsy), this is **catalog + redirect-link checkout + order**, not a full transactional adapter — for a more fundamental reason than Etsy. Instagram/Facebook Shops splits into two merchant populations:

- **"Checkout on your website"** — each catalog product carries its own merchant-hosted `url`. Buying happens entirely on the merchant's own site, never through Meta. This is the population `create_checkout` is built for: it redirects to that `url`, same posture as Etsy's listing-page redirect.
- **"Checkout on Instagram/Facebook"** — buying happens natively inside the Meta app, with **no exposed URL or API to drive it at all** — not even a redirect is possible here. Meta Commerce Orders from *this* population are the only ones `get_order` can ever see; this adapter can't originate a purchase for them, only read one back after the fact.

| UCP capability | Backing Graph API | Notes |
|---|---|---|
| `dev.ucp.shopping.catalog` | Commerce Catalog | `search_catalog`, `get_product` |
| `dev.ucp.shopping.checkout` | — | `create_checkout`/`get_checkout` only, redirect-link, "checkout on your website" catalogs only. `update_checkout`/`complete_checkout`/`cancel_checkout` raise `Portage::Ucp::NotImplementedError` — nothing to call. |
| `dev.ucp.shopping.order` | Commerce Orders | `get_order` — only returns data for "checkout on Instagram/Facebook" merchants; 403/404s for everyone else, since their orders live entirely in their own system |
| `dev.ucp.shopping.cart` | — | not implemented; no cart resource exists |
| `dev.ucp.shopping.identity` | — | not implemented; Instagram/Facebook user login is a separate concern from the Page/catalog token used here |

Same as Etsy: `create_checkout`'s Checkout objects are **not real Meta resources** — they live only in the `Adapter` instance's memory (`get_checkout` reads back what `create_checkout` stored), not surviving a process restart. `get_order`'s `checkout_id` is always blank for the same reason.

## Installation

```ruby
# Gemfile
gem "portage-ucp-instagram"
```

```bash
bundle install
```

## Setup

You need a long-lived Page/catalog access token and your Commerce Catalog id.

```ruby
require "portage/ucp/instagram"

client = Portage::Ucp::Instagram::Client.new(access_token: ENV.fetch("INSTAGRAM_ACCESS_TOKEN"))
adapter = Portage::Ucp::Instagram::Adapter.new(client: client, catalog_id: ENV.fetch("INSTAGRAM_CATALOG_ID"))
```

### Getting a long-lived access token

The initial short-lived token comes from Meta's interactive Business Login consent flow (outside this gem's scope). Exchange it for a long-lived one (~60 days):

```ruby
fetcher = Portage::Ucp::Instagram::AccessTokenFetcher.new(
  client_id: ENV.fetch("INSTAGRAM_CLIENT_ID"),
  client_secret: ENV.fetch("INSTAGRAM_CLIENT_SECRET"),
  short_lived_token: ENV.fetch("INSTAGRAM_SHORT_LIVED_TOKEN")
)

result = fetcher.fetch
result.access_token # => pass into Client.new
result.expires_in    # => ~5,184,000 seconds (60 days) — re-run Business Login after that, no refresh grant exists
```

## Usage

```ruby
# Catalog — product_id is the Graph API product node id
products = adapter.search_catalog(query: "mug", limit: 10)
product  = adapter.get_product(product_id: products.first.id)

# Checkout — a redirect, not a real transaction
checkout = adapter.create_checkout(
  line_items: [{ product_id: product.variants.first[:id], quantity: 1 }],
  idempotency_key: SecureRandom.uuid
)
checkout.links.first.url # => hand this to the shopper/agent to complete the purchase on the merchant's site

# Order — only works for "checkout on Instagram/Facebook" merchants
order = adapter.get_order(order_id: some_commerce_order_id)
```

## Wiring into portage-ucp

Drop the adapter into a `Dispatcher` (or the MCP server) the same as any other backend:

```ruby
dispatcher = Portage::Ucp::Dispatcher.new(adapter: adapter)

dispatcher.call(
  capability: "dev.ucp.shopping.checkout",
  action: "create_checkout",
  arguments: { line_items: [{ product_id: product_node_id, quantity: 1 }], idempotency_key: SecureRandom.uuid }
)
```

## Errors

```ruby
Portage::Ucp::Instagram::Error    # base class
Portage::Ucp::Instagram::ApiError # any non-2xx response from Meta's Graph API
```

## Development

```bash
bundle exec rspec   # tests (WebMock-stubbed, no live Meta account needed)
bundle exec rubocop  # lint

# exchange a real short-lived token for a long-lived one
INSTAGRAM_CLIENT_ID=... INSTAGRAM_CLIENT_SECRET=... INSTAGRAM_SHORT_LIVED_TOKEN=... \
  bundle exec rake instagram_access_token
```

## License

[MIT](LICENSE) — Copyright (c) 2026 Tom Whitbread.
