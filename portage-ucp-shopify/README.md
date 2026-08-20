# portage-ucp-shopify

Shopify adapter for [`portage-ucp`](../portage-ucp). Implements `Portage::Ucp::Adapter` against Shopify's Admin (catalog, order) and Storefront (cart, checkout) GraphQL APIs. Generic only — no merchant-specific business logic. Plain `Net::HTTP`, no `shopify_api` runtime dependency.

## What it covers

| UCP capability | Backing Shopify API | Notes |
|---|---|---|
| `dev.ucp.shopping.catalog` | Admin | `search_catalog`, `get_product` |
| `dev.ucp.shopping.cart` | Storefront (Cart) | `get_cart`, `create_cart`, `update_cart`, `cancel_cart` |
| `dev.ucp.shopping.checkout` | Storefront (same Cart object) | `create_checkout`, `get_checkout`, `update_checkout`, `complete_checkout`, `cancel_checkout` |
| `dev.ucp.shopping.order` | Admin | `get_order`, `cancel_order`, `refund_order`, `request_return` (gem-side extension beyond the real UCP spec — see below) |
| `dev.ucp.shopping.identity` | — | not implemented; Shopify's OAuth identity story lives in the separate Customer Account API, out of scope here |

Shopify has no separate "Checkout" object — Storefront's `Cart` **is** the checkout. The adapter tracks checkout status (`incomplete` / `completed` / `canceled` / `complete_in_progress`) itself, keyed by cart id, and resolves `Order#checkout_id` after completion via a `cart_token:` order search.

Update/replace operations (`update_cart`, `update_checkout`) are full-replacement: Storefront has no atomic "replace all lines" mutation, so the adapter removes every current line then re-adds the desired ones. Mutating methods dedup by `idempotency_key` in-process so a dropped-connection retry can't double-charge.

`cancel_order`, `refund_order`, and `request_return` cancel via `orderCancel`, refund via `suggestedRefund` + `refundCreate`, and request a return via `returnCreate`, respectively — each re-fetches the order afterwards rather than trusting the mutation's own payload, and the result shows up as an appended `Portage::Ucp::Adjustment` on `Order#adjustments` (type `cancellation`/`refund`/`return`). These three aren't in the real UCP spec's order lifecycle (get-only today) — they're a deliberate extension of the existing `dev.ucp.shopping.order` capability rather than a new top-level family, since it's the same resource as `get_order`.

## Installation

```ruby
# Gemfile
gem "portage-ucp-shopify"
```

```bash
bundle install
```

## Setup

You need a shop domain plus an Admin API access token (for catalog/order) and a Storefront API access token (for cart/checkout). Either capability can be used alone if you only pass the token it needs.

```ruby
require "portage/ucp/shopify"

client = Portage::Ucp::Shopify::Client.new(
  shop_domain: "your-shop.myshopify.com",
  admin_access_token: ENV.fetch("SHOPIFY_ADMIN_ACCESS_TOKEN"),
  storefront_access_token: ENV.fetch("SHOPIFY_STOREFRONT_ACCESS_TOKEN")
)

adapter = Portage::Ucp::Shopify::Adapter.new(client: client)
```

### Fetching an Admin token from a custom app's client credentials

Shopify custom apps no longer expose a static, copy-once admin token — only a `client_id`/`client_secret`. Exchange those for a real access token via OAuth's `client_credentials` grant:

```ruby
fetcher = Portage::Ucp::Shopify::AccessTokenFetcher.new(
  shop_domain: "your-shop.myshopify.com",
  client_id: ENV.fetch("SHOPIFY_CLIENT_ID"),
  client_secret: ENV.fetch("SHOPIFY_CLIENT_SECRET")
)

result = fetcher.fetch
result.access_token # => admin_access_token to pass into Client.new
result.expires_in    # => seconds until it needs refetching
```

## Usage

```ruby
# Catalog
products = adapter.search_catalog(query: "hoodie", limit: 10)
product  = adapter.get_product(product_id: products.first.id)

# Cart
cart = adapter.create_cart(
  line_items: [{ product_id: product.variants.first[:id], quantity: 2 }],
  idempotency_key: SecureRandom.uuid
)
cart = adapter.update_cart(cart_id: cart.id, line_items: [], idempotency_key: SecureRandom.uuid) # empties cart

# Checkout
checkout = adapter.create_checkout(
  line_items: [{ product_id: product.variants.first[:id], quantity: 1 }],
  idempotency_key: SecureRandom.uuid
)
checkout = adapter.complete_checkout(
  checkout_id: checkout.id,
  payment_token: single_use_token_from_payment_handler,
  idempotency_key: SecureRandom.uuid
)

# Order
order = adapter.get_order(order_id: checkout.id) # only once linked post-completion
```

`payment_token` must already be a single-use tokenized credential from a UCP payment handler (validated as non-PAN by `Portage::Ucp::PaymentTokenGuard` upstream) — it's passed straight into Storefront's `cartPaymentUpdate`.

## Wiring into portage-ucp

Drop the adapter into a `Dispatcher` (or the MCP server) the same as any other backend:

```ruby
dispatcher = Portage::Ucp::Dispatcher.new(adapter: adapter)

dispatcher.call(
  capability: "dev.ucp.shopping.cart",
  action: "create",
  arguments: { line_items: [{ product_id: variant_id, quantity: 1 }], idempotency_key: SecureRandom.uuid }
)
```

Because `link_identity` is left unoverridden, `Capability#advertised_for?` simply won't advertise `dev.ucp.shopping.identity` for this adapter — callers get an absent capability, not a 500.

## Errors

```ruby
Portage::Ucp::Shopify::Error        # base class
Portage::Ucp::Shopify::GraphqlError # top-level GraphQL `errors` (bad query, throttled, auth rejected)
Portage::Ucp::Shopify::UserError    # a mutation's non-empty `userErrors` (e.g. "line item not found")
```

## Development

```bash
bundle exec rspec   # tests (WebMock-stubbed, no live store needed)
bundle exec rubocop  # lint

# fetch a real admin_access_token for a dev store, via client_credentials
SHOPIFY_SHOP_DOMAIN=your-shop.myshopify.com \
SHOPIFY_CLIENT_ID=... SHOPIFY_CLIENT_SECRET=... \
  bundle exec rake shopify_access_token
```

## License

[MIT](LICENSE) — Copyright (c) 2026 Tom Whitbread.
