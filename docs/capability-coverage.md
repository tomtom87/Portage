# Capability coverage

## Capability coverage per adapter

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

A row-by-row, footnoted version of the same underlying data — including standalone-exe and
auth-type columns, and the Instagram order deprecation — lives on the
[feature matrix](adapters/feature-matrix.md).

**Who needs credentials here, and who doesn't:** the merchant sets this up *once*, using their own store's credentials (Shopify Admin token, WooCommerce consumer key, whatever). That's the only credentialed step in the whole system. After that manifest is live at `/.well-known/ucp`, **any shopper's AI agent — on any harness, with zero credentials of its own — can discover it and buy from it.** The shopper never sees a Shopify token or a WooCommerce key; they authenticate (if at all) with their own payment handler, not with your store. This is the same trust model as a merchant integrating hosted checkout today — one-time setup by the merchant, open-ended public use by anyone who finds it. See [the walkthrough](walkthrough.md) for the full "shopper agent → your live manifest → bought" path, credential-free the whole way.
