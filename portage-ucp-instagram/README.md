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

## Standalone MCP server

```bash
INSTAGRAM_ACCESS_TOKEN=... INSTAGRAM_CATALOG_ID=... bundle exec portage-ucp-instagram
```

Runs `exe/portage-ucp-instagram`, an MCP server over stdio wired straight to this Adapter. It ships with permissive-nothing defaults (an `UnconfiguredAuthenticator`/`NullRateLimiter`), so an MCP client can search/browse the catalog and nothing else until you wire a real `Authenticator`/`RateLimiter` via a `PORTAGE_UCP_CONFIG` file — the same hook `rackup -r`/Sidekiq's `-r` use:

```bash
PORTAGE_UCP_CONFIG=./config/portage_ucp.rb INSTAGRAM_ACCESS_TOKEN=... INSTAGRAM_CATALOG_ID=... \
  bundle exec portage-ucp-instagram
```

See [`examples/portage_ucp.rb`](examples/portage_ucp.rb) for a starting `PORTAGE_UCP_CONFIG` file (a minimal bearer-token `Authenticator` and in-process `RateLimiter`).

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
Portage::Ucp::Instagram::Error            # base class
Portage::Ucp::Instagram::ApiError         # any non-2xx response from Meta's Graph API
Portage::Ucp::Instagram::TokenExpiredError # code 190 — the access token is expired/invalid; re-mint it
```

`ApiError` exposes Meta's own error taxonomy alongside the HTTP `status`/`body`/`retry_after` every gem's `ApiError` carries: `#code`, `#error_subcode`, and `#fbtrace_id` (what Meta support asks for when escalating a request).

`Client#get` retries a bare 429/5xx and Meta's own platform-throttling codes (`4`, `17`, `32`, `613`, which arrive as a bare HTTP 400) with backoff honoring `Retry-After`. A `code: 190` (`OAuthException` — expired/invalid token) is never retried; it's raised as `TokenExpiredError` instead of `ApiError`, so it can't be mistaken for a business rejection — re-mint the token via Business Login consent and `AccessTokenFetcher`.

## ⚠️ Meta is sunsetting native checkout — `#get_order` has a shrinking window

Meta phased out native "Checkout on Instagram/Facebook" for all US merchants by August 2025, and is following through at the API level: Graph API v26.0 (July 2026) already blocks the ~47 Commerce Order Management endpoints (order retrieval/listing, line items, payments, refunds, shipments, returns, tax settings) for that reason, and **the same block extends to every supported API version — including this gem's `v21.0` — on October 27, 2026**, at which point the endpoint is removed entirely, with no replacement. `#get_order` only ever served the "Checkout on Instagram/Facebook" population in the first place (see the class-level comment on `Adapter`); after that date it has no merchants left to serve. `search_catalog`/`get_product` (Commerce Catalog) are unaffected — the sunset is Orders-specific.

`#get_order` keeps working, unchanged, until the cutoff — it's deprecated, not yet removed. Each `Adapter` instance emits a one-time `Kernel#warn` the first time `#get_order` is called, pointing at this section, so a long-lived process (e.g. `exe/portage-ucp-instagram`) doesn't spam stderr on every subsequent call. After 2026-10-27 this adapter becomes **catalog + checkout-handoff only**: `search_catalog`/`get_product`/`create_checkout`/`get_checkout` are unaffected, but `#get_order` will start raising instead of returning data, and `dev.ucp.shopping.order` should no longer be advertised for this adapter — track the next major/minor release notes for the exact removal.

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
