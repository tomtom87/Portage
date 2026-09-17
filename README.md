# Portage::Ucp

[![gem version](https://img.shields.io/gem/v/portage-ucp)](https://rubygems.org/gems/portage-ucp)
![ruby](https://img.shields.io/badge/ruby-%3E%3D%203.2-red)
![license](https://img.shields.io/badge/license-MIT-blue)

Ruby gems that expose a commerce backend to AI shopping agents over **MCP** ([Model Context Protocol](https://modelcontextprotocol.io)) and **UCP** ([Universal Commerce Protocol](https://ucp.dev)) at once. Open-source, for any Ruby app on any e-commerce stack, agnostic, versatile and fully customizable for any business logic.

"Portage": a conduit for cargo overland between waterways a ship can't sail directly between.

> **Status**: `0.8.0`. APIs may still shift before `1.0` — see the [design log](docs/design-log.md).

## Quick start, buying via cli

```bash
gem install portage-cli
```

```bash
# Search for products — never touches payment or checkout, safe to run freely - by default supports duckduckgo, Google, Brave. 
portage find --query "usb-c cable" --max-price 20 --json

# Dry run search-and-buy pipeline, stops before checkout so we can see the
# price/path it would take with no charge either way
portage buy --query "wireless mouse" --max-price 40 --dry-run --json

# Use a URL, skips search, goes straight to its /.well-known/ucp manifest
portage buy https://some-ucp-store.example --query "hoodie" --yes --payment-token "$TOKEN"
```

`buy` tries native UCP discovery first (any store serving a real `/.well-known/ucp`
manifest), then falls back to a platform adapter only when this process already has
that platform's own credentials (`SHOPIFY_ADMIN_ACCESS_TOKEN`, etc. — see
[Requirements](#requirements)). `find` covers the no-URL case, `history`/`payment`/
`policy` manage local purchase history, stored payment tokens, and spend caps. 

**Full walkthrough** — install, search, dry-run buy, seeding a store allowlist, what to do when
the free search backend comes back empty — in
[`docs/cli-usage-tutorial.md`](docs/cli-usage-tutorial.md).

**Pointing an agent at it:** rather than hand-roll prompts, drop the
[`skills/shop-via-ucp`](skills/shop-via-ucp/SKILL.md) skill into your agent's skills
directory (Claude Code, or anything else that reads the same `SKILL.md` convention). It
tells the agent to prefer the `portage-ucp-client` gem or the `portage` CLI over raw MCP
tool calls when either is available, and encodes the guardrails that matter even when
neither is (discover a manifest before assuming any credential path, treat
`requires_escalation` as data rather than an error, never let a raw card number reach
`payment_token`). [`skills/serve-via-ucp`](skills/serve-via-ucp/SKILL.md) is the
merchant-side counterpart, for pointing an agent at *setting up* a store's own UCP
endpoint instead.

## Contents

- [Installation](#installation)
- [Usage](#usage)
- [The gems](#the-gems)
- [Security hooks](#security-hooks--nothing-is-permissive-by-default)
- [How the pieces fit together](#how-the-pieces-fit-together)
- [Writing your own adapter](#writing-your-own-adapter)
- [Checking any store](#checking-any-store)
- [Spec conformance](#spec-conformance)
- [Requirements](#requirements)
- [Development](#development)
- [Contributing](#contributing)
- [License](#license)

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
server.start # stdio, or mount as Streamable HTTP per the `mcp` gem's own docs
```

That's a running MCP server, wired up inline. Every adapter gem also ships an
executable that does steps 1 and 3 for you, so you don't need a throwaway Ruby file
just to point an MCP client (Claude Desktop, etc.) at a `command`:

```bash
bundle exec portage-ucp-shopify   # stdio, reads SHOPIFY_SHOP_DOMAIN /
                                   # SHOPIFY_ADMIN_ACCESS_TOKEN / SHOPIFY_STOREFRONT_ACCESS_TOKEN
```

Step 2 (wiring a real `authenticator`/`rate_limiter`/`business`) still has to come from
you — the exe won't guess those — so point `PORTAGE_UCP_CONFIG` at a Ruby file that
calls `Portage::Ucp.configure`, the same `-r`-a-file pattern `rackup`/Sidekiq use.
[`portage-ucp-shopify/examples/portage_ucp.rb`](portage-ucp-shopify/examples/portage_ucp.rb)
is a copy-paste starting point (bearer-token authenticator, in-process rate limiter):

```bash
PORTAGE_UCP_CONFIG=./config/portage_ucp.rb bundle exec portage-ucp-shopify
```

Without it, the server still starts but rejects every mutating call — the
`UnconfiguredAuthenticator` default from [Security hooks](#security-hooks--nothing-is-permissive-by-default) below.

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

Five tool calls, one snowboard bought. [`docs/walkthrough.md`](docs/walkthrough.md) shows what's actually running behind each of those — auth checks, PAN rejection, idempotent retries — plus how to serve the discovery manifest and order webhooks, from the shopper agent's side.

## The gems

Eleven gems, mirroring how Faraday/Devise split core-vs-adapter:

| Gem | Role |
|---|---|
| [`portage-ucp`](portage-ucp/) | Protocol-only core: `Adapter` contract, capability registry, manifest builder, MCP server wrapper. Zero commerce-backend deps — works with any backend that implements `Adapter`, Shopify or otherwise. |
| [`portage-ucp-client`](portage-ucp-client/) | Client-side SDK — the other direction from every gem below: connect to somebody else's manifest (or drive your own `Adapter` directly) and act as the shopper's agent. Loopback/stdio/HTTP transports behind one interface. |
| [`portage-ucp-journal`](portage-ucp-journal/) | Buyer-side purchase journal + the injectable `Store` abstraction it's built on (design-log §22) — an append-only record of every completed purchase, kept out of core so `portage-ucp` stays dependency-light. Wires in via `Dispatcher`'s optional `journal:` argument. |
| [`portage-cli`](portage-cli/) | Ships the `portage` command — `portage buy <url>` tries native UCP discovery first, falls back to a platform adapter only when you already have that platform's own credentials, and says so plainly otherwise. `portage find --query "..."` covers the no-URL case: search backends propose stores, `/.well-known/ucp` filters them, their catalogs answer. `portage history` browses the local log of past purchases and searches. `portage payment list/enroll/set-default/remove/freeze/revoke` stores card-on-file tokens (macOS Keychain / Linux Secret Service / a headless env-var-only tier) so `buy` can fall back to a stored default instead of demanding a fresh token every call; `portage policy show/set` manages the caps/velocity/allowlist `PolicyGuard` checks. |
| [`portage-ucp-shopify`](portage-ucp-shopify/) | Shopify adapter — implements `Adapter` against Shopify's Admin + Storefront GraphQL APIs. One consumer of the core gem, not a dependency of it. |
| [`portage-ucp-wix`](portage-ucp-wix/) | Wix adapter — implements `Adapter` against Wix's Stores Catalog and eCommerce REST APIs. |
| [`portage-ucp-woocommerce`](portage-ucp-woocommerce/) | WooCommerce adapter — implements `Adapter` against a WooCommerce site's Admin REST API and Store API. |
| [`portage-ucp-bigcommerce`](portage-ucp-bigcommerce/) | BigCommerce adapter — implements `Adapter` against a BigCommerce store's v3 Catalog/Carts/Checkouts APIs and v2 Orders API. |
| [`portage-ucp-magento`](portage-ucp-magento/) | Magento/Adobe Commerce adapter — implements `Adapter` against a Magento site's REST v1 API (admin-token catalog/order, anonymous guest-cart cart/checkout). |
| [`portage-ucp-etsy`](portage-ucp-etsy/) | Etsy adapter — real catalog/order against Etsy's Open API v3; checkout is redirect-link only (Etsy's public API has no cart/checkout endpoint). |
| [`portage-ucp-instagram`](portage-ucp-instagram/) | Instagram/Facebook Shops adapter — real catalog against Meta's Graph API Commerce Catalog; checkout is redirect-link only, and order lookup only works for "checkout on Instagram/Facebook" merchants. |

A backend on some other stack (a hand-rolled Rails store, another platform entirely) writes its own thin `Adapter` subclass against `portage-ucp` directly — the adapters above are just the ones that exist today. Not every backend has a real cart/checkout API to back — Etsy and Instagram/Facebook Shops don't, so those two adapters only implement catalog/order for real and fall back to a redirect-link `Checkout` instead of a full transactional one (see their READMEs).

Each adapter gem also ships the same `exe/` executable, `examples/portage_ucp.rb` starting point, and `PORTAGE_UCP_CONFIG` hook shown in [Usage](#usage) — see [Requirements](#requirements) for the env vars each one reads.

**Already on Shopify and wondering why you'd need this at all** — Shopify ships its own native Universal Commerce Agent app that auto-serves `/.well-known/ucp` with checkout+order capabilities, no code required. This gem is for the gap that app leaves: `cart`/`catalog` capabilities it doesn't advertise, a signed manifest it can't produce, and a self-hosted setup for backends other than Shopify. Full comparison in [`docs/well-known-ucp.md`](docs/well-known-ucp.md).

### Capability coverage per adapter

A capability is advertised in the manifest as soon as an adapter overrides *any one* of its backing `Adapter` methods (`Capability#advertised_for?`, `portage-ucp/lib/portage/ucp/capability.rb`) — ✅ below means every backing method is overridden, 🟡 means only some are (the rest raise `Portage::Ucp::NotImplementedError` if called), and — means none are, so the capability isn't advertised at all. Derived by reading each adapter's actual method definitions, not its docs.

| Capability | Shopify | Wix | WooCommerce | BigCommerce | Magento | Etsy | Instagram |
|---|---|---|---|---|---|---|---|
| `dev.ucp.shopping.catalog` | ✅ | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 |
| `dev.ucp.shopping.cart` | ✅ | ✅ | ✅ | ✅ | ✅ | — | — |
| `dev.ucp.shopping.checkout` | ✅ | ✅ | ✅ | ✅ | ✅ | 🟡 | 🟡 |
| `dev.ucp.shopping.order` | ✅ | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 | 🟡 |
| `dev.ucp.shopping.discount` | ✅ | — | — | — | — | — | — |
| `dev.ucp.shopping.fulfillment` | ✅ | — | — | — | — | — | — |
| `dev.ucp.shopping.identity` | — | — | — | — | — | — | — |
| `app.portage-ucp.reorder` | — | — | — | — | — | — | — |
| `app.portage-ucp.payment_enrollment` / `payment_method` / `shopper_data` | — | — | — | — | — | — | — |

- **catalog 🟡** (Wix/WooCommerce/BigCommerce/Magento/Etsy/Instagram): missing `lookup_catalog` — the batch-fetch-by-ids variant of `search_catalog`/`get_product`.
- **checkout 🟡** (Etsy, Instagram): only `create_checkout`/`get_checkout` — both platforms are redirect-link checkout only, so `update_checkout`/`complete_checkout`/`cancel_checkout` have nothing to back them.
- **order 🟡** (Wix/WooCommerce/BigCommerce/Magento/Etsy/Instagram): only `get_order` — `cancel_order`/`request_return`/`refund_order` aren't implemented yet.
- **identity, reorder, and the `app.portage-ucp.*` extensions** (payment enrollment, saved payment methods/addresses, shopper-data erasure) aren't implemented by any bundled adapter yet — a consumer needing one of these today writes it against their own `Adapter` subclass directly.

**Who needs credentials here, and who doesn't:** the merchant sets this up *once*, using their own store's credentials (Shopify Admin token, WooCommerce consumer key, whatever). That's the only credentialed step in the whole system. After that manifest is live at `/.well-known/ucp`, **any shopper's AI agent — on any harness, with zero credentials of its own — can discover it and buy from it.** The shopper never sees a Shopify token or a WooCommerce key; they authenticate (if at all) with their own payment handler, not with your store. This is the same trust model as a merchant integrating hosted checkout today — one-time setup by the merchant, open-ended public use by anyone who finds it. See [`docs/walkthrough.md`](docs/walkthrough.md) for the full "shopper agent → your live manifest → bought" path, credential-free the whole way.

## Security hooks — nothing is permissive by default

Read this before wiring a server up to anything real — every default here is deliberately locked down, not permissive-by-omission:

- **Authentication**: `Portage::Ucp::UnconfiguredAuthenticator` (the default) rejects every mutating call until you configure a real one. Implement `#call(server_context)` to return a truthy auth context, or raise `Portage::Ucp::AuthenticationError`.
- **Rate limiting**: `Portage::Ucp::NullRateLimiter` (the default) never limits. Implement `#check!(key, capability)` and raise `Portage::Ucp::RateLimitExceededError` to block a call.
- **PAN guard**: `Portage::Ucp::PaymentTokenGuard` rejects any `payment_token` that looks like a raw card number (digits-only, Luhn-valid, 12–19 chars) before it ever reaches your `Adapter` — `complete_checkout` must receive a tokenized credential.
- **Idempotency**: every mutating capability action takes an `idempotency_key:` — your `Adapter` is responsible for deduping retries (see `portage-ucp-shopify`'s in-process dedup table for one approach).
- **Observability**: `Portage::Ucp::Observability.log` emits structured JSON log events through a consumer-injected logger, redacting `payment_token`/`oauth_token`/`authorization` automatically.
- **Manifest signing**: `Portage::Ucp::Manifest` never generates or stores keys — pass a `signer` (anything responding to `#kid` and `#sign(canonical_json)`) to produce a signed manifest; omit it to serve unsigned.
- **Policy caps**: `Portage::Ucp::PolicyGuard`, wired into `Dispatcher` just before `complete_checkout` dispatch, enforces `Portage::Ucp::Policy`'s per-transaction/rolling caps, velocity limits, and merchant allowlist — plus per-token enrollment scopes (merchant/max-amount/currency) bound at enrollment time and checked by the same `token_ref` at charge time. Configured via `portage-cli`'s `portage policy show/set` and `portage payment enroll --scope-*`.
- **Confirmation**: `Portage::Ucp::Confirmer`, run right after `PolicyGuard.check!` passes and before `complete_checkout` dispatch. `Confirmer::Terminal` blocks on stdin and fails closed on anything but an explicit `"y"`; `Confirmer::AutoApprove` is for specs/conformance kits that need a real `confirm!` without blocking; `Confirmer::Webhook` is for out-of-band approval — POSTs to a configured URL and polls (or calls a caller-supplied `wait:` callback) until approve/deny/timeout, failing closed on timeout like `Terminal` but with a longer default (900s vs. 120s).
- **Payment enrollment**: `Portage::Ucp::PaymentEnrollmentGuard`, run via `Dispatcher#call`, validates every `create_payment_enrollment`/`get_payment_enrollment` response an adapter returns — `"pending"` must carry a `setup_url` and no `payment_token`, `"complete"` the reverse — raising `InvalidPaymentEnrollmentError` on a violation. An optional `mandate:` kwarg on the same two methods is shape-checked by `Portage::Ucp::Ap2::MandateGuard` (AP2 mandate shape, not cryptographic verification).
- **Inbound request signatures**: `Portage::Ucp::Security::Signature` / `Rack::SignatureVerification` verify RFC 9421 HTTP Message Signatures on inbound requests per UCP's signature spec — the same verify-before-parse posture as `Rack::WebhookEndpoint`, trusting `Manifest#signing_keys`' current+next JWK array.
- **Durable records**: `Portage::Ucp::Support::TransactionLog` reserves a transaction before `complete_checkout` dispatch and marks it settled/failed after, recording `PolicyGuard`/`Confirmer` outcomes on the same record. `Portage::Ucp::Support::OrderLedger` writes a durable snapshot alongside it once settlement succeeds — a failed snapshot write surfaces without flipping an already-settled charge to failed.

## How the pieces fit together

```
Your backend
    ↓ implements
Portage::Ucp::Adapter (catalog/cart/checkout/order/identity methods)
    ↓ registered against
Portage::Ucp::CapabilityRegistry  (which capabilities does this adapter actually support?)
    ↓ used by
Portage::Ucp::Dispatcher          (routes a capability+action call to the Adapter method)
    ↓ wrapped by
Portage::Ucp::Mcp::Server.build   (generates MCP::Tool objects, one per advertised action)
    ↓ served over
stdio / Streamable HTTP (via the `mcp` gem)

Portage::Ucp::Manifest             (builds the signed /.well-known/ucp discovery doc)
    ↓ served by
Portage::Ucp::Rack::ManifestEndpoint

Portage::Ucp::Rack::WebhookEndpoint (HMAC-verified inbound order-lifecycle webhooks)
```

A capability (e.g. `dev.ucp.shopping.cart`) is only advertised if your `Adapter` overrides at least one of its backing methods — an unconfigured method just means that capability doesn't show up in the manifest or the MCP tool list, not a 500.

## Writing your own adapter

```ruby
class MyAdapter < Portage::Ucp::Adapter
  def search_catalog(query:, limit:) = ...
  def get_product(product_id:) = ...
  def create_cart(line_items:, idempotency_key:) = ...
  # override only the capabilities you support — the rest stay unadvertised
end
```

See `Portage::Ucp::Adapter` for the full method contract (catalog, cart, checkout, order, identity linking, reorder), `Portage::Ucp::ReferenceAdapter` (ships with the core gem, `lib/portage/ucp/reference_adapter.rb`) for a complete in-memory implementation of every capability including discount/fulfillment/identity/reorder, and `portage-ucp-shopify`'s `Adapter` for a real one against a live commerce API.

`reorder` (`app.portage-ucp.reorder`) is a Portage-owned extension, not part of the UCP spec: it hydrates a `Cart` from a past order's line items, re-checking each item's current availability rather than replaying historical prices, and reports anything no longer purchasable via `ReorderResult#unavailable_items` instead of failing outright.

`payment_method` / `saved_address` / `shopper_data` (`app.portage-ucp.payment_method`, `app.portage-ucp.saved_address`, `app.portage-ucp.shopper_data`) are Portage-owned extensions too, shipped together: saved payment references and addresses, plus the erasure path that removes them (and the shopper's linked identity) in one call. `oauth_token:` is the authorization boundary on every method here, including the two `list_*` reads — see `Portage::Ucp::Adapter`'s doc comments on `save_payment_method` for why a bare `subject:` string would be a lookup vulnerability. `save_payment_method`'s `payment_token:` runs through the same `PaymentTokenGuard` Luhn/format check as `complete_checkout`, and `delete_shopper_data` is idempotent — safe to call again on an already-erased subject.

### Checking your adapter against the contract

`Portage::Ucp::SchemaValidator` (see [Spec conformance](#spec-conformance) below) checks that your `Adapter`'s output matches UCP's wire schemas, but schema-valid output can still violate the contract's behavioral guarantees — an idempotency key that isn't actually deduped, a raw PAN reaching your adapter, a capability that's advertised but doesn't round-trip through its own schema. The core gem ships a conformance kit, an RSpec shared-examples suite, for that:

```ruby
# spec/spec_helper.rb
require "portage/ucp/rspec"

# spec/my_adapter_spec.rb
RSpec.describe MyAdapter do
  it_behaves_like "a portage adapter" do
    let(:adapter) { MyAdapter.new(client: my_test_client) }
    let(:existing_product_id) { "known-good-product-id" } # real/stubbed, in-stock, purchasable
    # optional — enables the out-of-stock example:
    # let(:out_of_stock_product_id) { "known-sold-out-product-id" }
  end
end
```

Not loaded by `require "portage/ucp"` — it pulls in RSpec, which the core gem otherwise has zero runtime dependency on. Every example skips itself when your adapter doesn't advertise the capability it needs, so an adapter that only does catalog and checkout still runs it cleanly.

All seven bundled adapter gems run it against their real `Adapter` (`spec/portage/ucp/<platform>/conformance_spec.rb` in each), and `spec/reference_adapter_conformance_spec.rb` in the core gem runs it against `ReferenceAdapter` — so it's exercised by CI on every push, not just documented. One canned backend response per call the kit makes is enough for a stubbed adapter: the repeat-key example is answered from the in-process dedup table without a second HTTP call, and the PAN example is rejected inside `Dispatcher` before `complete_checkout` runs. Include `Portage::Ucp::Support::Idempotency` in your adapter (as every bundled one does) and the dedup example checks the table itself rather than just comparing the two calls' output — output equality alone is satisfied by any fixed-response test double, deduped or not.

## Checking any store

`portage-ucp-check` is a small CLI, shipped with the core gem, for the question this whole README has been building toward: "does this store need portage-ucp at all, and if so, which adapter?"

```bash
bundle exec portage-ucp-check your-shop.example
```

It tries the cheap answer first — `GET /.well-known/ucp` on the URL you gave it. If that's already there (a Shopify store with the native Universal Commerce Agent app, say), it prints the manifest as-is and stops; no adapter needed.

If there's no native manifest, it looks at the homepage for platform tells (Shopify's `cdn.shopify.com`, WooCommerce's plugin path, BigCommerce's CDN host, etc.) and names the matching `portage-ucp-<adapter>` gem. When that adapter's env vars (the same ones its `exe/` reads — see [Requirements](#requirements) below) are already set, it goes one step further: requires the gem, builds a real `Client`/`Adapter`, and calls `search_catalog` against the live store, so the recommendation is a confirmed-working adapter rather than a guess from string-matching.

```json
{
  "url": "https://your-shop.example",
  "native_ucp": null,
  "platform": "WooCommerce",
  "recommended_gem": "portage-ucp-woocommerce",
  "live_probe": {
    "status": "skipped",
    "reason": "missing env vars: WOOCOMMERCE_SITE_URL, WOOCOMMERCE_CONSUMER_KEY, WOOCOMMERCE_CONSUMER_SECRET"
  }
}
```

`live_probe.status` is one of `ok` (adapter built and fetched a real product), `skipped` (env vars absent, or the adapter gem isn't installed), or `error` (adapter built but the live call failed — bad credentials, wrong store, etc.). Exits `0` when it found something usable — a native manifest or a working live probe — `1` otherwise, so it's scriptable in CI ("does this store already speak UCP, yes or no").

## Spec conformance

`Portage::Ucp::SchemaValidator` validates data against UCP's own vendored JSON Schemas/OpenRPC docs offline (no network calls, no reliance on ucpchecker.com as a CI gate) — useful in your own test suite if you want to assert your adapter's output is schema-conformant beyond what `to_wire_h` already guarantees.

## Requirements

- Ruby >= 3.2
- `mcp` gem `~> 0.24` (pulled in by `portage-ucp`)

Each adapter gem needs its backend's own credentials, read from env by its executable. Its README has the full detail on obtaining them and on any capability it can't back for real:

| Gem | Executable | Required env vars |
|---|---|---|
| [`portage-ucp-shopify`](portage-ucp-shopify/) | `portage-ucp-shopify` | `SHOPIFY_SHOP_DOMAIN`, `SHOPIFY_ADMIN_ACCESS_TOKEN` and/or `SHOPIFY_STOREFRONT_ACCESS_TOKEN` — each capability family works independently if you only have one |
| [`portage-ucp-wix`](portage-ucp-wix/) | `portage-ucp-wix` | `WIX_ACCESS_TOKEN` (site-scoped, exchanged from an app client_id/client_secret plus the site's instance_id) |
| [`portage-ucp-woocommerce`](portage-ucp-woocommerce/) | `portage-ucp-woocommerce` | `WOOCOMMERCE_SITE_URL`, `WOOCOMMERCE_CONSUMER_KEY`, `WOOCOMMERCE_CONSUMER_SECRET`; optional `WOOCOMMERCE_CURRENCY` (default `USD`), `WOOCOMMERCE_PAYMENT_METHOD` (for `complete_checkout`) |
| [`portage-ucp-bigcommerce`](portage-ucp-bigcommerce/) | `portage-ucp-bigcommerce` | `BIGCOMMERCE_STORE_HASH`, `BIGCOMMERCE_CLIENT_ID`, `BIGCOMMERCE_ACCESS_TOKEN`, `BIGCOMMERCE_SITE_URL`; optional `BIGCOMMERCE_CURRENCY` (default `USD`), `BIGCOMMERCE_PAYMENT_GATEWAY_ID` (for `complete_checkout`) |
| [`portage-ucp-magento`](portage-ucp-magento/) | `portage-ucp-magento` | `MAGENTO_BASE_URL`, `MAGENTO_ADMIN_TOKEN`; optional `MAGENTO_CURRENCY` (default `USD`), `MAGENTO_SITE_URL`, `MAGENTO_PAYMENT_METHOD`/`MAGENTO_DEFAULT_ADDRESS` (a JSON object, for `complete_checkout`) |
| [`portage-ucp-etsy`](portage-ucp-etsy/) | `portage-ucp-etsy` | An Etsy OAuth access_token (shop-owner consent) plus your app's `x-api-key` — catalog/order only, checkout is redirect-link |
| [`portage-ucp-instagram`](portage-ucp-instagram/) | `portage-ucp-instagram` | A Meta Graph API long-lived access token plus your Commerce Catalog id — catalog only, checkout is redirect-link |

## Development

Each gem manages its own tests/lint independently — its own `Gemfile`/`Gemfile.lock`, own `spec/`, no shared state or run-order dependency between gems:

```bash
cd portage-ucp && bundle exec rspec && bundle exec rubocop
```

Or run the full suite across every gem in one command, via the root `Rakefile` — it just shells into each gem dir in turn and stops at the first failure, no root-level bundle or cross-gem dependency involved:

```bash
rake spec   # == rake, spec is the default task
```

See the [design log](docs/design-log.md) for the rationale and decision history behind this project.

### Releasing a gem

`gem build` must be run from inside the gem's own directory, not the workspace root — every gemspec's `spec.files = Dir["lib/**/*.rb", ...]` resolves against whatever the current directory is, so building from the wrong place silently produces an empty package (see the 0.7.1 postmortem in the [changelog](CHANGELOG.md)). Before pushing a build, run it through `release_check`, which builds the gem from its own directory and smoke-tests that the resulting package actually installs and `require`s:

```bash
rake release_check[portage-ucp]
```

Only push to RubyGems once that passes.

## Contributing

Bug reports and pull requests welcome at [tomtom87/Portage](https://github.com/tomtom87/Portage). Since this is pre-`1.0` and still spec-tracking, open an issue to discuss any change bigger than a bugfix before sending a PR — the capability/adapter contract is still settling.

Run `rake spec` for the gem(s) you touched before opening a PR — CI (`.github/workflows/ci.yml`) runs `rspec`/`rubocop` for every gem on push and PR too, but running it locally first is faster than waiting on the matrix.

A new platform adapter is the most welcome kind of PR: subclass `Portage::Ucp::Adapter` in `portage-ucp` against the target platform's API, following the shape of an existing adapter gem (`portage-ucp-shopify` is the most complete reference), and add it to the gem table above.

## License

[MIT](LICENSE) — Copyright (c) 2026 Tom Whitbread.
