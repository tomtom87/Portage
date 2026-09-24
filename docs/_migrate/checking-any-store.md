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
