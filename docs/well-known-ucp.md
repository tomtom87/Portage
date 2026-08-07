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
// GET /.well-known/ucp — Shopify's native manifest
{
  "ucp_version": "2026-01-23",
  "business": { "name": "Your Store" },
  "capabilities": [
    { "name": "dev.ucp.shopping.checkout", "version": "1" },
    { "name": "dev.ucp.shopping.order", "version": "1" }
  ],
  "payment_handlers": [],
  "signing_keys": []
}
```

Two gaps this leaves, both of which `Portage::Ucp::Manifest` closes: `signing_keys` is always empty — Shopify's app doesn't generate or hold keys, so an agent that verifies manifest authenticity (Google's do) treats it as unverified — and its `ucp_version` trails the spec this gem targets (`2026-04-08`). `dev.ucp.shopping.cart` and `dev.ucp.shopping.catalog` aren't advertised at all — that's the gap `portage-ucp-shopify`'s `Adapter` fills, on top of the same `/.well-known/ucp` path, just self-hosted and signed.
