# Why `/.well-known/ucp`?

`/.well-known/<name>` is [RFC 8615](https://www.rfc-editor.org/rfc/rfc8615)'s standard location for site-wide metadata a client should be able to find without any prior coordination — no custom DNS record, no per-integration config, just a fixed, predictable path any crawler or agent already knows to check. It's the same slot `/.well-known/security.txt` and `/.well-known/openid-configuration` use. UCP reuses it for the same reason: an agent that has never talked to your store before can hit `https://your-shop.example/.well-known/ucp` cold and get back capabilities, payment handlers, and signing keys.

## Alongside `llms.txt`, not in place of it

It sits alongside, not in place of, [`llms.txt`](https://llmstxt.org) — a related-but-different convention some sites use to hand an LLM a curated, human-readable index of pages worth reading (docs, key content) in place of scraping raw HTML. `llms.txt` describes *content* for an LLM to read; `/.well-known/ucp` describes *capabilities* an agent can call. A store could reasonably serve both.

`llms.txt` is normally its own plain file at the site root (`/llms.txt`, markdown):

```markdown
# Your Store

> Online retailer of snowboards and winter gear.

## Docs
- [Shipping policy](/pages/shipping): rates, timelines, international.
- [Size guide](/pages/size-guide): board length by rider weight/height.

## Optional
- [Blog](/blog): buying guides and gear reviews.
```

...but it doesn't have to live at that exact path — some sites instead point to it from HTML `<head>`, the same discovery pattern as `rel="sitemap"` or `rel="alternate"`:

```html
<link rel="llms.txt" href="/docs/llms.txt">
```

That lets an agent already parsing your page's `<head>` find the file without guessing the root path — useful if it lives somewhere other than `/llms.txt`, or you want it scoped per-section (e.g. `/blog/llms.txt` linked only from blog pages).

Shopify stores get a default `/llms.txt` generated automatically for the storefront (product/collection/page links, no merchant config needed) — same "don't reimplement what the platform already ships" reasoning as its native Universal Commerce Agent app for `/.well-known/ucp` (see the [design log](design-log.md) §1). This gem's Shopify adapter targets the gap: catalog/cart/checkout/order over UCP+MCP, which the default `llms.txt` doesn't cover.

## What Shopify already serves, and what it leaves out

With no merchant config, once Shopify's Universal Commerce Agent app is installed:

```
GET https://your-shop.myshopify.com/llms.txt
GET https://your-shop.myshopify.com/.well-known/ucp
```

```json
// GET /.well-known/ucp — Shopify's native manifest. Trimmed from a live
// store's, fetched 2026-09-29. Every entry also has "spec" and "schema"
// URLs, and some have "extends", "requires" or "config". Those are left out.
{
  "ucp": {
    "version": "2026-08-25",
    "supported_versions": {
      "2026-04-08": "https://your-shop.myshopify.com/.well-known/ucp/2026-04-08",
      "2026-01-23": "https://your-shop.myshopify.com/.well-known/ucp/2026-01-23"
    },
    "services": {
      "dev.ucp.shopping": [
        { "version": "2026-08-25", "transport": "mcp", "endpoint": "https://your-shop.myshopify.com/api/ucp/mcp" },
        { "version": "2026-04-08", "transport": "embedded" }
      ]
    },
    "capabilities": {
      "dev.ucp.shopping.catalog.search": [{ "version": "2026-08-25" }],
      "dev.ucp.shopping.catalog.lookup": [{ "version": "2026-08-25" }],
      "dev.shopify.catalog": [{ "version": "2026-08-25" }],
      "dev.ucp.shopping.cart": [{ "version": "2026-08-25" }],
      "dev.ucp.shopping.checkout": [{ "version": "2026-08-25" }],
      "dev.ucp.shopping.fulfillment": [{ "version": "2026-08-25" }],
      "dev.ucp.shopping.discount": [{ "version": "2026-08-25" }],
      "dev.ucp.shopping.order": [{ "version": "2026-08-25" }],
      "dev.ucp.common.identity_linking": [{ "version": "2026-08-25" }]
    },
    "payment_handlers": {
      "com.google.pay": [{ "id": "gpay", "version": "2026-01-11" }],
      "dev.shopify.card": [{ "id": "shopify.card", "version": "2026-01-15" }],
      "dev.shopify.shop_pay": [{ "id": "shop_pay", "version": "2026-04-08" }]
    }
  }
}
```

Everything nests under `ucp`, and `services`, `capabilities` and `payment_handlers` are keyed by name. `Portage::Ucp::Manifest` has used the same nesting since `portage-ucp` 0.8.0, and keys `services` and `payment_handlers` by name too as of the 2026-08-25 move (a bare `config.services` array is filed under `dev.ucp.shopping`; `config.payment_handlers` must be a Hash). `Portage::Ucp::Client.discover` reads both this shape and the older flat one.

The gap is signing. There's no `keys` and no signature, so an agent has nothing to verify the manifest against. `Portage::Ucp::Manifest` emits `keys` (a JWK Set, a sibling of `ucp` at the document root, as UCP 2026-08-25 requires), and signs the body when you give it a signer. The config option is still called `signing_keys`.

Cart and catalog are both advertised. Shopify splits catalog into `dev.ucp.shopping.catalog.search` and `dev.ucp.shopping.catalog.lookup`. `Portage::Ucp::Manifest` advertises one `dev.ucp.shopping.catalog` for all three catalog actions (see the [tool-gating investigation](ucp-tool-gating-investigation.md)).
