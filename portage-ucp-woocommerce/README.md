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

## ⚠️ Verified against a local install

Run against a throwaway Docker WooCommerce (WP 7.1.1 + WooCommerce 11.1.1, TLS via a local Caddy reverse proxy — see `docs/plans/woocommerce-local-validation.md` for the full setup and test ladder). What actually held up, and what didn't:

**Confirmed working:**
- Admin REST Basic Auth, `Client#store_request`'s `Cart-Token`/`Nonce` session threading across `create_cart` → `update_cart` → `create_checkout` → `get_checkout`, and `Resolver.detect_platform` all work exactly as coded — against a real store, not just WebMock stubs.
- `POST /cart/add-item` accepts a variable product's variation id directly as `id` — no separate `variation` param needed, confirmed live.
- `Mapper.variant`'s `attributes[].option` join produces correct titles (e.g. `"Blue / Yes"`) against a real variable product.
- Store API money fields map to correct minor units through `Mapper`.

**Fixed since this pass:**

1. **Hand-off now fires on WooCommerce, and lands on a populated cart.** `Mapper.checkout` builds a `resume-checkout` link at `<site_url>/checkout/?session=<cart_token>` (WooCommerce's default checkout slug — a store that's renamed its checkout page gets a dead link) for any non-completed checkout, so `Buy#checkout_url_of`/`#hand_off` have something to work with instead of bailing early on `links: []`. The `?session=` query param matters: without it, the browser lands on `/checkout/` with an *empty* cart, because the CLI's cart lives in the Store API's token-based session while `/checkout/` reads the classic cookie-based one — two different rows in `wp_woocommerce_sessions`. WooCommerce core ships the bridge itself (`WC_Session_Handler#init_session_from_request` accepts the same Cart-Token JWT as `?session=` and clones that guest session into a fresh cookie session before the page renders), confirmed live: `--auto-open` now opens a browser straight onto a checkout page with the actual cart contents.
2. **`Resolver` now threads `payment_method`/`billing_address` through to the adapter.** Its WooCommerce entry was missing both from its `env:` map, so `complete_checkout` failed with no gateway or address configured even when `WOOCOMMERCE_PAYMENT_METHOD`/`WOOCOMMERCE_BILLING_ADDRESS` were set.
3. **`portage buy`'s `adapter_flow` no longer hides a live adapter's own error.** It rescued `LoadError` and `StandardError` identically, so a real, actionable failure (e.g. "no payment_method configured on this Adapter") surfaced as the same generic "no automated path" dead end as an adapter that isn't installed at all. A `StandardError` past that point now comes back as its own report, distinguishable by `source`.
4. **`submit_checkout` now supplies `billing_address`.** `POST /wc/store/v1/checkout` 400s without one; there's no UCP `complete_checkout` parameter for it, so — same stopgap posture as `payment_method` — the adapter takes one fixed `billing_address` hash at construction time via `WOOCOMMERCE_BILLING_ADDRESS` (JSON, Store API field names), not per-checkout. Fine for a single-buyer-per-process, wrong the moment something needs a different address per checkout.

**Remaining gaps, still unfixed:**

1. **`requires_escalation` is unreachable here.** The Woo adapter only ever records `incomplete`/`completed`/`canceled` — there's no path to that status on this backend at all.
2. **A dry run does not write to the purchase journal**, contrary to earlier assumption. `PurchaseJournal#record_checkout` only fires from `Dispatcher`'s `complete_checkout` settle point — a dry run only ever reaches `create_checkout`, so `~/.portage/journal.jsonl` is untouched. Confirmed by running two dry runs and finding no journal file created at all.

Also worth knowing: WooCommerce's Basic Auth for the Admin API only activates when `is_ssl()` is true (`WC_REST_Authentication#authenticate`) — over plain HTTP it silently falls through to OAuth1 query-param signing instead, which this client doesn't implement. A local HTTP-only install will get a generic `401 woocommerce_rest_cannot_view`, not an auth-scheme error; put TLS in front (even a local self-signed proxy) before debugging keys.

## Installation

```ruby
# Gemfile
gem "portage-ucp-woocommerce"
```

```bash
bundle install
```

## Setup

You need a site URL, an Admin REST API consumer key/secret pair (wp-admin → WooCommerce → Settings → Advanced → REST API — grant Read/Write), your store's currency (the Admin product resource doesn't return one), and — only if you'll call `complete_checkout` — the WC payment gateway id you want to submit orders through and a `billing_address` the Store API's `/checkout` endpoint requires.

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
  payment_method: "stripe_cc", # only required for #complete_checkout
  billing_address: { "first_name" => "...", "address_1" => "...", "city" => "...",
                      "postcode" => "...", "country" => "..." } # only required for #complete_checkout
)
```

## Usage

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

## License

[MIT](LICENSE) — Copyright (c) 2026 Tom Whitbread.
