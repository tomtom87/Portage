# Checking any store

## With the `portage` CLI

```bash
portage check your-shop.example
portage check your-shop.example --json
```

`portage check` answers "can Portage buy from this store, and how?" and gives the answer `portage buy` would act on. It wraps the check described below, then adds what only the CLI knows: whether the host is on your hand-off-only list (or is a built-in hand-off retailer such as Amazon, Walmart, eBay, Best Buy or Etsy), whether the matching adapter gem is installed and which env vars it still needs, and whether the store's page exposes WebMCP tools.

`verdict` is one of:

| Verdict | Meaning |
|---|---|
| `automated` | The store speaks UCP natively, or a configured adapter answered a live probe. |
| `webmcp` | Portage can build the cart through the page's WebMCP tools. You pay in your browser. |
| `handoff` | A hand-off-only host, or a platform was detected but its adapter isn't usable. Portage opens the store and you buy. |
| `unsupported` | Nothing usable was found. |

`next_step` says in plain English what to do about it. It exits `0` for `automated` and `webmcp`, `1` otherwise, and takes the same `--proxy*` flags as `buy` and `find`. The full field list is in [the CLI JSON reference](api/cli-json.md#check).

`check` sends plain GET requests only and never builds a cart. A hand-off-only host is not contacted at all. WebMCP tools exist only on a live page, so `check` reads them from a tab your Portage browser profile already has open on that store (`portage browser profile open --url URL`); it never launches a browser. Without one, or without `portage-ucp-webmcp` installed, `webmcp.status` is `skipped` and `reason` says why.

## With `portage-ucp-check` (library only)

If you only have the core gem, `portage-ucp-check` is a small CLI, shipped with the core gem, for the question this whole documentation set has been building toward: "does this store need portage-ucp at all, and if so, which adapter?"

```bash
bundle exec portage-ucp-check your-shop.example
```

It tries the cheap answer first — `GET /.well-known/ucp` on the URL you gave it. If that's already there (a Shopify store with the native Universal Commerce Agent app, say), it prints the manifest as-is and stops; no adapter needed. If not, it looks for a `<link rel="ucp" href="...">` manifest pointer in the homepage, the same fallback `portage buy` follows, and reports that manifest with its `manifest_url`.

If there's no native manifest, it looks at the homepage for platform tells (Shopify's `cdn.shopify.com`, WooCommerce's plugin path, BigCommerce's CDN host, etc.) and names the matching `portage-ucp-<adapter>` gem. When that adapter's env vars (the same ones its `exe/` reads — see [Adapter requirements](adapter-requirements.md)) are already set, it goes one step further: requires the gem, builds a real `Client`/`Adapter`, and calls `search_catalog` against the live store, so the recommendation is a confirmed-working adapter rather than a guess from string-matching.

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
