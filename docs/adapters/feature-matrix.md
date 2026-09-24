# Adapter feature matrix

Derived by reading each adapter's actual `Adapter#` method definitions (not its README) —
`portage-ucp-<platform>/lib/portage/ucp/<platform>/adapter.rb` — plus the capability
registry's advertisement rule in `portage-ucp/lib/portage/ucp/capability.rb`
(`Capability#advertised_for?`: a capability is advertised as soon as *any one* of its
backing methods is overridden). ✅ = implemented for real, — = not implemented (method
isn't overridden, so the action isn't advertised at all), ⚠️ = implemented but with a
caveat noted in a footnote below. Derived 2026-09-24.

| | Shopify | Wix | WooCommerce | BigCommerce | Magento | Etsy | Instagram |
|---|---|---|---|---|---|---|---|
| Catalog search | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Product detail | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Catalog lookup (batch by id) | ✅ | — | — | — | — | — | — |
| Cart (get/create/update/cancel) | ✅ | ✅ | ✅ | ✅ | ✅ | — | — |
| Checkout create | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Checkout get | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Checkout update | ✅ | ✅ | ✅ | ✅ | ✅ | —[^redirect] | —[^redirect] |
| Checkout complete | ✅ | ✅ | ✅ | ✅ | ✅ | —[^redirect] | —[^redirect] |
| Checkout cancel | ✅ | ✅ | ✅ | ✅ | ✅ | —[^redirect] | —[^redirect] |
| Discount codes | ✅ | — | — | — | — | — | — |
| Fulfillment options | ✅ | — | — | — | — | — | — |
| Order get | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ⚠️[^ig-order] |
| Order cancel | ✅ | — | — | — | — | — | — |
| Order refund | ✅ | — | — | — | — | — | — |
| Order return (RMA) | ✅ | — | — | — | — | — | — |
| Payment method / saved address / shopper data | — | — | — | — | — | — | — |
| Auth type | Admin + Storefront token | Site-scoped OAuth access token | Consumer key/secret (Basic Auth) | Client id + access token | Admin bearer token | OAuth 2.0 (PKCE) access token + `x-api-key` | Long-lived Graph API (Page/catalog) token |
| Standalone exe | ✅ | ✅ | ✅ | ✅ | ✅ | ✅[^pending-exe] | ✅[^pending-exe] |

[^redirect]: Etsy's and Instagram's public APIs have no cart/checkout endpoint at all —
    `create_checkout`/`get_checkout` return a redirect link to the platform's own hosted
    checkout, so there's nothing for `update_checkout`/`complete_checkout`/`cancel_checkout`
    to back. See [the Etsy adapter](etsy.md) and [the Instagram adapter](instagram.md).

[^ig-order]: Instagram's `get_order` is **deprecated**: Meta removes Order Management
    endpoints on **2026-10-27**. After that date this adapter is catalog search/product +
    checkout handoff only — there is no replacement order-status API on Meta's side.

[^pending-exe]: Etsy and Instagram gain `exe/` + `examples/portage_ucp.rb` via the
    `feat/etsy-exe` and `harden/instagram` branches (not yet merged as of this writing) —
    describing the post-merge state, all seven bundled adapters ship the same standalone
    executable, example config, and `PORTAGE_UCP_CONFIG` hook (see
    [Library usage](../library-usage.md)).

See [Capability coverage](../capability-coverage.md) for the same data organized by UCP
capability id rather than by adapter, and [Adapter requirements](../adapter-requirements.md)
for the exact environment variables each executable reads.
