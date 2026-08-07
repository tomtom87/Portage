# portage-ucp-magento

Magento/Adobe Commerce adapter for [`portage-ucp`](../portage-ucp). Implements `Portage::Ucp::Adapter` against a Magento site's REST v1 API. Generic only — no merchant-specific business logic. Plain `Net::HTTP`, no Magento PHP SDK dependency.

## What it covers

| UCP capability | Backing Magento API | Notes |
|---|---|---|
| `dev.ucp.shopping.catalog` | Admin-token REST v1 | `search_catalog`, `get_product` |
| `dev.ucp.shopping.cart` | Anonymous guest-cart REST v1 | `get_cart`, `create_cart`, `update_cart`, `cancel_cart` |
| `dev.ucp.shopping.checkout` | Same guest-cart, plus `shipping-information`/`payment-information` | `create_checkout`, `get_checkout`, `update_checkout`, `complete_checkout`, `cancel_checkout` |
| `dev.ucp.shopping.order` | Admin-token REST v1 | `get_order` |
| `dev.ucp.shopping.identity` | — | not implemented; Magento customer account login is a separate concern from the admin token + anonymous guest-cart flow used here |

Like Shopify, a Magento guest cart *is* the checkout — there's no separate Checkout resource, just the same cart plus two extra calls at completion time. Cart/checkout ids are Magento's masked guest-cart id, not a numeric id. Line items are keyed by **sku**, not product id — that's what Magento's `cartItem` payloads take, so `product_id` in every `line_items:` argument means sku here.

Update/replace operations (`update_cart`, `update_checkout`) are full-replacement: the guest-cart items API has no atomic "replace all lines" either, so the adapter removes every current line then re-adds the desired ones. Mutating methods dedup by `idempotency_key` in-process so a dropped-connection retry can't double-charge.

Like Shopify/Wix, there's an `AccessTokenFetcher` — but it's a plain username/password exchange (`/rest/V1/integration/admin/token`), not a client_credentials grant, and Magento doesn't report an expiry, so plan to refresh on a 401 rather than a known lifetime.

## ⚠️ Unverified against a live site, and one real gap

Built from Magento's documented REST shapes, not run against a real site yet.

- **`#complete_checkout` needs an address UCP doesn't carry.** Magento's real guest-checkout flow requires a billing/shipping address before `payment-information` will create an order, but `complete_checkout(checkout_id:, payment_token:, idempotency_key:)` has no address parameter at all. This adapter works around that with a single `default_address:` configured once at initialization — every order ships and bills to the same address. That's fine for a single-fulfillment-address integration (e.g. all-digital goods, or a business account with one known destination) and wrong for anything where the address varies per order. A real UCP address extension, if one lands, would replace this.
- **`payment_data` shape is gateway-specific** (configured via `payment_method:`/`payment_data_key:`) and hasn't been confirmed against a live site with a real payment gateway installed — same posture as the other adapters' payment steps.
- **Order fulfillment** — Magento core has no per-line-item fulfillment tracking on the Order resource (that's the separate Shipments API), so every order line gets the same coarse status derived from the order's own top-level `status`.
- **`Order#permalink_url`** — left blank; Magento's Orders API doesn't return a public order-status page URL.
- **Configurable product variant titles** — built from each child's own `name`, not verified against how a real store names its configurable children.

## Installation

```ruby
# Gemfile
gem "portage-ucp-magento"
```

```bash
bundle install
```

## Setup

You need a base URL, an admin bearer token (catalog/order), your store's currency (the product resource doesn't return one), and — only if you'll call `complete_checkout` — a payment method id and a default address.

```ruby
require "portage/ucp/magento"

client = Portage::Ucp::Magento::Client.new(
  base_url: "https://your-shop.example.com",
  admin_token: ENV.fetch("MAGENTO_ADMIN_TOKEN")
)

adapter = Portage::Ucp::Magento::Adapter.new(
  client: client,
  currency: "USD",
  site_url: "https://your-shop.example.com",
  payment_method: "checkmo", # only required for #complete_checkout
  default_address: { firstname: "Store", lastname: "Fulfillment", street: ["1 Main St"], city: "Boston",
                     region: "MA", postcode: "02110", country_id: "US", telephone: "555-0100",
                     email: "orders@your-shop.example.com" }
)
```

### Fetching an admin token from username/password

```ruby
fetcher = Portage::Ucp::Magento::AccessTokenFetcher.new(
  base_url: "https://your-shop.example.com",
  username: ENV.fetch("MAGENTO_USERNAME"),
  password: ENV.fetch("MAGENTO_PASSWORD")
)

result = fetcher.fetch
result.access_token # => admin_token to pass into Client.new
```

## Usage

```ruby
# Catalog — product_id is a sku, e.g. "cold-brew"
products = adapter.search_catalog(query: "cold brew", limit: 10)
product  = adapter.get_product(product_id: products.first.id)

# Cart — cart_id is only known after the first call, since Magento assigns
# it (as a masked guest-cart id) rather than taking one from the caller
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
  arguments: { line_items: [{ product_id: "cold-brew", quantity: 1 }], idempotency_key: SecureRandom.uuid }
)
```

Because `link_identity` is left unoverridden, `Capability#advertised_for?` simply won't advertise `dev.ucp.shopping.identity` for this adapter — callers get an absent capability, not a 500.

## Errors

```ruby
Portage::Ucp::Magento::Error    # base class
Portage::Ucp::Magento::ApiError # any non-2xx response from Magento's REST API
```

## Development

```bash
bundle exec rspec   # tests (WebMock-stubbed, no live site needed)
bundle exec rubocop  # lint

# fetch a real admin token for a dev site
MAGENTO_BASE_URL=https://your-shop.example.com \
MAGENTO_USERNAME=... MAGENTO_PASSWORD=... \
  bundle exec rake magento_access_token
```

## License

[MIT](LICENSE) — Copyright (c) 2026 Tom Whitbread.
