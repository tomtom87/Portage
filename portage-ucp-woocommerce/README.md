# portage-ucp-woocommerce

WooCommerce adapter for [`portage-ucp`](../portage-ucp). Implements `Portage::Ucp::Adapter` against a WooCommerce site's Admin REST API v3 (catalog, order) and Store API v1 (cart, checkout). Generic only — no merchant-specific business logic. Plain `Net::HTTP`, no `woocommerce-api` runtime dependency.

## What it covers

| UCP capability | Backing WooCommerce API | Notes |
|---|---|---|
| `dev.ucp.shopping.catalog` | Admin REST v3 | `search_catalog`, `get_product` |
| `dev.ucp.shopping.cart` | Store API (Cart) | `get_cart`, `create_cart`, `update_cart`, `cancel_cart` |
| `dev.ucp.shopping.checkout` | Store API (same Cart, plus `/checkout`) | `create_checkout`, `get_checkout`, `update_checkout`, `complete_checkout`, `cancel_checkout` |
| `dev.ucp.shopping.order` | Admin REST v3 | `get_order` |
| `dev.ucp.shopping.identity` | — | not implemented; WordPress/WooCommerce user auth is a separate concern from the Admin keys + anonymous Store API session used here |

Like Shopify, WooCommerce has no separate "Checkout" object — the Store API's Cart **is** the checkout, identified by an opaque `Cart-Token` session header rather than a resource id. The adapter tracks checkout status itself, keyed by that token, and records `Order#checkout_id` itself at completion time (WooCommerce orders don't link back to their originating cart natively).

Update/replace operations (`update_cart`, `update_checkout`) are full-replacement: the Store API has no atomic "replace all lines" mutation either, so the adapter removes every current line then re-adds the desired ones. Mutating methods dedup by `idempotency_key` in-process so a dropped-connection retry can't double-charge.

Unlike Shopify/Wix, there's no `AccessTokenFetcher` — WooCommerce Admin keys are static, generated once in wp-admin (WooCommerce → Settings → Advanced → REST API), with nothing to exchange or expire.

## ⚠️ Unverified against a live site

Built from WooCommerce's documented REST/Store API shapes, not run against a real site yet. Before relying on this in production, confirm:

- **`#complete_checkout`** — posts `payment_method` + `payment_data` to the Store API's `/checkout` endpoint. `payment_method` must match an installed, enabled WC gateway id, and the `payment_data` key a gateway expects (`payment_data_key:`, default `"token"`) is gateway-specific — Stripe's block-based gateway and PayPal's don't necessarily read the same key. Needs confirming against a live site with a real gateway installed.
- **Variable product variants** — `Mapper.variant`'s title is built by joining `attributes[].option`; not verified against a real variable product's actual attribute shape.
- **Order fulfillment** — WooCommerce core has no per-line-item fulfillment tracking (that's a shipment-tracking-plugin concern), so every order line is given the same coarse status derived from the order's own top-level `status`, not a real per-line signal.
- **Store API checkout response shape** — assumed to carry the same `items`/`totals` shape as the Cart response, plus `order_id`. Not confirmed live.

## Installation

```ruby
# Gemfile
gem "portage-ucp-woocommerce"
```

```bash
bundle install
```

## Setup

You need a site URL, an Admin REST API consumer key/secret pair (wp-admin → WooCommerce → Settings → Advanced → REST API — grant Read/Write), your store's currency (the Admin product resource doesn't return one), and — only if you'll call `complete_checkout` — the WC payment gateway id you want to submit orders through.

```ruby
require "portage/ucp/woocommerce"

client = Portage::Ucp::WooCommerce::Client.new(
  site_url: "https://your-shop.example.com",
  consumer_key: ENV.fetch("WOOCOMMERCE_CONSUMER_KEY"),
  consumer_secret: ENV.fetch("WOOCOMMERCE_CONSUMER_SECRET")
)

adapter = Portage::Ucp::WooCommerce::Adapter.new(
  client: client,
  site_url: "https://your-shop.example.com",
  currency: "USD",
  payment_method: "stripe_cc" # only required for #complete_checkout
)
```

## Using the adapter directly

```ruby
# Catalog
products = adapter.search_catalog(query: "hoodie", limit: 10)
product  = adapter.get_product(product_id: products.first.id)

# Cart — cart_id is only known after the first call, since the Store API
# assigns it (as a Cart-Token) rather than taking one from the caller
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
Portage::Ucp::WooCommerce::Error    # base class
Portage::Ucp::WooCommerce::ApiError # any non-2xx response from either the Admin or Store API
```

## Development

```bash
bundle exec rspec   # tests (WebMock-stubbed, no live site needed)
bundle exec rubocop  # lint

# verify a real site's Admin key/secret by listing one product
WOOCOMMERCE_SITE_URL=https://your-shop.example.com \
WOOCOMMERCE_CONSUMER_KEY=... WOOCOMMERCE_CONSUMER_SECRET=... \
  bundle exec rake woocommerce_smoke_test
```
