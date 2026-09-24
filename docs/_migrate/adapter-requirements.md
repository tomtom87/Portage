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

