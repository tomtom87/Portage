# portage-ucp-etsy

Etsy adapter for [`portage-ucp`](../portage-ucp). Implements `Portage::Ucp::Adapter` against Etsy's Open API v3. Generic only — no merchant-specific business logic. Plain `Net::HTTP`, no Etsy SDK runtime dependency.

## What it covers — and what it deliberately doesn't

Unlike the other adapters in this project, this is **catalog + redirect-link checkout + order**, not a full transactional adapter. Etsy's public API has no cart, checkout, or add-to-cart endpoint at all — buying only ever happens on etsy.com itself.

| UCP capability | Backing Etsy API | Notes |
|---|---|---|
| `dev.ucp.shopping.catalog` | Open API v3 | `search_catalog` (client-side title filter, see below), `get_product` |
| `dev.ucp.shopping.checkout` | — | `create_checkout`/`get_checkout` only. `update_checkout`/`complete_checkout`/`cancel_checkout` are left unoverridden — calling them raises `Portage::Ucp::NotImplementedError` rather than pretending to do something. `dev.ucp.shopping.checkout` is still advertised (one overridden method is enough), so an agent discovers what's actually backed by trying it. |
| `dev.ucp.shopping.order` | Open API v3 (shop receipts) | `get_order` |
| `dev.ucp.shopping.cart` | — | not implemented at all; there's no Etsy cart resource to back it |
| `dev.ucp.shopping.identity` | — | not implemented; Etsy buyer/seller OAuth identity is a separate concern from the shop-owner token used here |

**`create_checkout`'s `Checkout#links` point at each requested listing's own etsy.com page** — the closest real equivalent to "add to cart and check out" this API allows. These Checkout objects are **not real Etsy resources** — nothing on Etsy's side tracks them. They live only in the `Adapter` instance's memory (`get_checkout` just reads back what `create_checkout` stored), so they don't survive a process restart or a different `Adapter` instance. `get_order`'s `checkout_id` is always blank for the same underlying reason: there's no real checkout for a receipt to link back to.

**`search_catalog` is weaker than every other adapter's.** Etsy's shop-listings endpoint supports no keyword filter (only limit/offset/sort) — this fetches a page of active listings and filters by title client-side. Fine for a small shop, misleading for a large one with more listings than fit in one page.

## Installation

```ruby
# Gemfile
gem "portage-ucp-etsy"
```

```bash
bundle install
```

## Setup

You need an OAuth access_token (from the shop owner's one-time consent — Etsy's authorization-code+PKCE flow, outside this gem's scope) and your app's `x-api-key` (the OAuth client's keystring, required on every request in addition to the bearer token).

```ruby
require "portage/ucp/etsy"

client = Portage::Ucp::Etsy::Client.new(
  access_token: ENV.fetch("ETSY_ACCESS_TOKEN"),
  api_key: ENV.fetch("ETSY_API_KEY")
)

adapter = Portage::Ucp::Etsy::Adapter.new(client: client, shop_id: ENV.fetch("ETSY_SHOP_ID"))
```

### Refreshing the access token

Etsy access tokens expire quickly and **rotate the refresh_token on every use** — persist the new one each time, the old one stops working immediately.

```ruby
fetcher = Portage::Ucp::Etsy::AccessTokenFetcher.new(
  client_id: ENV.fetch("ETSY_CLIENT_ID"),
  refresh_token: ENV.fetch("ETSY_REFRESH_TOKEN")
)

result = fetcher.fetch
result.access_token   # => pass into Client.new
result.refresh_token  # => save this — the old one is now invalid
result.expires_in     # => seconds until it needs refreshing again
```

## Using the adapter directly

```ruby
# Catalog — product_id is Etsy's listing_id
products = adapter.search_catalog(query: "mug", limit: 10)
product  = adapter.get_product(product_id: products.first.id)

# Checkout — a redirect, not a real transaction
checkout = adapter.create_checkout(
  line_items: [{ product_id: product.variants.first[:id], quantity: 1 }],
  idempotency_key: SecureRandom.uuid
)
checkout.links.first.url # => hand this to the shopper/agent to complete the purchase on etsy.com

# Order
order = adapter.get_order(order_id: some_receipt_id)
```

## Wiring into portage-ucp

Drop the adapter into a `Dispatcher` (or the MCP server) the same as any other backend:

```ruby
dispatcher = Portage::Ucp::Dispatcher.new(adapter: adapter)

dispatcher.call(
  capability: "dev.ucp.shopping.checkout",
  action: "create_checkout",
  arguments: { line_items: [{ product_id: listing_id, quantity: 1 }], idempotency_key: SecureRandom.uuid }
)
```

## Errors

```ruby
Portage::Ucp::Etsy::Error    # base class
Portage::Ucp::Etsy::ApiError # any non-2xx response from Etsy's Open API v3
```

## Development

```bash
bundle exec rspec   # tests (WebMock-stubbed, no live Etsy account needed)
bundle exec rubocop  # lint

# refresh a real access_token for a connected shop
ETSY_CLIENT_ID=... ETSY_REFRESH_TOKEN=... bundle exec rake etsy_access_token
```
