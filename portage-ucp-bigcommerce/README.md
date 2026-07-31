# portage-ucp-bigcommerce

BigCommerce adapter for [`portage-ucp`](../portage-ucp). Implements `Portage::Ucp::Adapter` against a BigCommerce store's v3 Catalog/Carts/Checkouts APIs and v2 Orders API. Generic only — no merchant-specific business logic. Plain `Net::HTTP`, no `bigcommerce_api` runtime dependency.

## What it covers

| UCP capability | Backing BigCommerce API | Notes |
|---|---|---|
| `dev.ucp.shopping.catalog` | v3 Catalog | `search_catalog`, `get_product` |
| `dev.ucp.shopping.cart` | v3 Carts | `get_cart`, `create_cart`, `update_cart`, `cancel_cart` |
| `dev.ucp.shopping.checkout` | v3 Checkouts (shares its cart's id), plus Orders + Payments to complete | `create_checkout`, `get_checkout`, `update_checkout`, `complete_checkout`, `cancel_checkout` |
| `dev.ucp.shopping.order` | v2 Orders | `get_order` |
| `dev.ucp.shopping.identity` | — | not implemented; BigCommerce's storefront Customer Login API is a separate concern from the store-owner API account used here |

Unlike Shopify/WooCommerce, BigCommerce's Checkout **is** a distinct resource from its Cart — but they share the same id, created together by a single `POST /carts` call. `update_cart`/`update_checkout` are full-replacement: the Carts API has no atomic "replace all lines" endpoint, so the adapter adds the desired lines *before* removing the old ones — BigCommerce auto-deletes a cart when its last remaining line item is removed, so removing old lines first would destroy the cart the call is supposed to be updating. `cancel_cart` deletes the cart resource outright (BigCommerce is the only one of the three adapters whose Carts API actually supports this). Mutating methods dedup by `idempotency_key` in-process so a dropped-connection retry can't double-charge.

Unlike Shopify/Wix, there's no `AccessTokenFetcher` — a BigCommerce API account (Settings → API → Create API Account) hands back a static `client_id`/`access_token` pair with no expiry, same posture as `portage-ucp-woocommerce`. The separate OAuth authorization-code flow BigCommerce uses for public Marketplace apps is a different concern, out of scope here.

## ⚠️ Unverified against a live store

Built from BigCommerce's documented REST API shapes, not run against a real store yet. Before relying on this in production, confirm:

- **`#complete_checkout`** — creates an order from the checkout, mints a single-order Payment Access Token, then submits `payment_token` as a tokenized instrument to the separate Payments API (`payments.bigcommerce.com`). The exact `payment_instrument` shape a given gateway expects (`payment_gateway_id:`) is gateway-specific and hasn't been confirmed against a live store with a real gateway installed.
- **Cart/Checkout line item price fields** — `Mapper.cart_line_item` assumes plain decimal fields (`sale_price`, `extended_sale_price`); some BigCommerce API surfaces instead nest money under a `{value:, currency:}` sub-object.
- **`Order#permalink_url`** — built from BigCommerce's documented storefront order-status route, not confirmed against a live storefront theme.
- **Order fulfillment** — BigCommerce core has no per-line-item fulfillment tracking, so every order line is given the same coarse status derived from the order's own `status_id`, not a real per-line signal.

## Installation

```ruby
# Gemfile
gem "portage-ucp-bigcommerce"
```

```bash
bundle install
```

## Setup

You need your store hash (from the BigCommerce control panel URL or API path), and a client_id/access_token pair from an API account (Settings → API → Create API Account — grant the scopes you need for Products/Carts/Checkouts/Orders), your store's currency (the Catalog product resource doesn't return one), and — only if you'll call `complete_checkout` — the payment gateway id you want to submit orders through.

```ruby
require "portage/ucp/bigcommerce"

client = Portage::Ucp::BigCommerce::Client.new(
  store_hash: ENV.fetch("BIGCOMMERCE_STORE_HASH"),
  client_id: ENV.fetch("BIGCOMMERCE_CLIENT_ID"),
  access_token: ENV.fetch("BIGCOMMERCE_ACCESS_TOKEN")
)

adapter = Portage::Ucp::BigCommerce::Adapter.new(
  client: client,
  site_url: "https://your-shop.example.com",
  currency: "USD",
  payment_gateway_id: "stripe" # only required for #complete_checkout
)
```

## Using the adapter directly

```ruby
# Catalog
products = adapter.search_catalog(query: "hoodie", limit: 10)
product  = adapter.get_product(product_id: products.first.id)

# Cart — cart_id comes back from the create response
cart = adapter.create_cart(
  line_items: [{ product_id: product.variants.first[:id], quantity: 2 }],
  idempotency_key: SecureRandom.uuid
)
cart = adapter.update_cart(cart_id: cart.id, line_items: [], idempotency_key: SecureRandom.uuid) # empties cart

# Checkout — shares the same id as the cart it was created from
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
order = adapter.get_order(order_id: checkout_order_id) # only once linked post-completion
```

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
Portage::Ucp::BigCommerce::Error    # base class
Portage::Ucp::BigCommerce::ApiError # any non-2xx response from the Admin or Payments API
```

## Development

```bash
bundle exec rspec   # tests (WebMock-stubbed, no live store needed)
bundle exec rubocop  # lint

# verify a real store's client_id/access_token by listing one product
BIGCOMMERCE_STORE_HASH=abc123 \
BIGCOMMERCE_CLIENT_ID=... BIGCOMMERCE_ACCESS_TOKEN=... \
  bundle exec rake bigcommerce_smoke_test
```
