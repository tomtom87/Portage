# portage-ucp-wix

Wix adapter for [`portage-ucp`](../portage-ucp). Implements `Portage::Ucp::Adapter` against Wix's Stores (catalog) and eCommerce (cart, checkout, order) REST APIs. Generic only — no merchant-specific business logic. Plain `Net::HTTP`, no Wix SDK runtime dependency.

## What it covers

| UCP capability | Backing Wix API | Notes |
|---|---|---|
| `dev.ucp.shopping.catalog` | Stores Catalog V1 | `search_catalog`, `get_product` |
| `dev.ucp.shopping.cart` | eCommerce Carts | `get_cart`, `create_cart`, `update_cart`, `cancel_cart` |
| `dev.ucp.shopping.checkout` | eCommerce Checkouts | `create_checkout`, `get_checkout`, `update_checkout`, `complete_checkout`, `cancel_checkout` |
| `dev.ucp.shopping.order` | eCommerce Orders | `get_order` |
| `dev.ucp.shopping.identity` | — | not implemented; Wix Members/visitor OAuth is a separate concern from the site-level app auth used here |

Unlike Shopify, Wix models Cart and Checkout as genuinely separate resources, and a Wix Order links back to its originating Checkout natively via `checkoutId` — no cart-token reconciliation search needed for `Order#checkout_id`.

Update/replace operations (`update_cart`, `update_checkout`) are full-replacement: Wix's add/remove-line-items endpoints aren't an atomic "replace all lines" either, so the adapter removes every current line then re-adds the desired ones. Mutating methods dedup by `idempotency_key` in-process so a dropped-connection retry can't double-charge.

## ⚠️ Unverified against a live site

This adapter is built from Wix's documented REST API shapes but hasn't been run against a real Wix site. Before relying on it in production, confirm:

- **Catalog shape** — targets Stores Catalog **V1** (`priceData`, `stock`, `productPageUrl`, variant `choices`), not V3. If your site's app only has V3 access, `Mapper.product`/`.variant` need rewriting against V3's shape.
- **`#complete_checkout`** — calls Wix's `create-order` endpoint bare. Wix's documented flow expects payment to already be authorized through a connected payment provider (Wix Payments or a PSP) before an order is created; there's no confirmed Wix equivalent of Shopify's `cartPaymentUpdate` that accepts an arbitrary single-use token. `payment_token` is accepted for interface parity with other `Portage::Ucp` adapters but currently isn't sent anywhere — wiring real payment capture needs confirming against a live site with a configured payment provider.
- **Order fulfillment** — Wix order line items only expose a coarse `fulfillmentStatus` (not/partially/fully fulfilled quantities); `Order#fulfillment` is left as `{}` since real per-shipment tracking would need Wix's separate Fulfillments API, which isn't wired up here.
- **`Order#permalink_url`** — left blank; Wix's Orders API doesn't return a public order-status page URL.

## Installation

```ruby
# Gemfile
gem "portage-ucp-wix"
```

```bash
bundle install
```

## Setup

You need a single site-scoped access token — unlike Shopify's split Admin/Storefront tokens, Wix's REST surface sits behind one token, already scoped to a site.

```ruby
require "portage/ucp/wix"

client = Portage::Ucp::Wix::Client.new(access_token: ENV.fetch("WIX_ACCESS_TOKEN"))
adapter = Portage::Ucp::Wix::Adapter.new(client: client)
```

### Fetching an access token from an app's client credentials

```ruby
fetcher = Portage::Ucp::Wix::AccessTokenFetcher.new(
  client_id: ENV.fetch("WIX_CLIENT_ID"),
  client_secret: ENV.fetch("WIX_CLIENT_SECRET"),
  instance_id: ENV.fetch("WIX_INSTANCE_ID")
)

result = fetcher.fetch
result.access_token # => access_token to pass into Client.new
result.expires_in    # => seconds until it needs refetching
```

## Using the adapter directly

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
Portage::Ucp::Wix::Error    # base class
Portage::Ucp::Wix::ApiError # any non-2xx Wix REST response (bad auth, malformed request, business rejection)
```

## Development

```bash
bundle exec rspec   # tests (WebMock-stubbed, no live site needed)
bundle exec rubocop  # lint

# fetch a real access_token for a dev site, via client_credentials
WIX_CLIENT_ID=... WIX_CLIENT_SECRET=... WIX_INSTANCE_ID=... \
  bundle exec rake wix_access_token
```
