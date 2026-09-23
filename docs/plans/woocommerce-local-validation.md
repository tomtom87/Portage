# Validating `portage buy` against a local WooCommerce (Docker)

**Status:** done — all rungs run against a live Docker WooCommerce install (WP 7.1.1, WooCommerce 11.1.1). Findings folded into `portage-ucp-woocommerce`'s README. Stack lives at `tmp/woo-local/` (untracked); `docker compose down -v` there to tear it down.
**Driver:** [`portage-ucp-woocommerce`](../../portage-ucp-woocommerce/README.md) carries an explicit "⚠️ Unverified against a live site" section, and [checkout-handoff-delivery.md](checkout-handoff-delivery.md) just shipped a hand-off path (auto-open + webhook) whose three trigger sites have only ever been exercised against WebMock stubs and the Shopify loopback. Neither the adapter's Store API assumptions nor the hand-off wiring has met a real WooCommerce install. We have no test store; we do have Docker.

**Goal of this pass:** get a throwaway WooCommerce running locally, drive `portage buy --dry-run` end to end against it, then push one step past dry run to the `no_payment_token` dead end and see whether the hand-off actually fires. Findings, not fixes — fixes get their own pass.

## What we already expect to break

Read before running anything; these are static reads of the code, not observations, and each one is a thing the run is meant to confirm or refute.

1. **The hand-off almost certainly can't fire on WooCommerce at all.** `Mapper.checkout` ([mapper.rb:99](../../portage-ucp-woocommerce/lib/portage/ucp/woocommerce/mapper.rb#L99)) builds every `Checkout` with `links: []`. `Buy#checkout_url_of` reads `checkout["links"].find { |l| l["url"] }`, so it returns `nil`, and `Buy#hand_off` returns `nil` early on a `nil` url. Expected observed result: the `no_payment_token` branch prints its message with `checkout_url: nil` and no `handoff` sub-hash. If so, the fix is Woo-side (`links` should carry the store's `/checkout` page URL), not CLI-side.
2. **`requires_escalation` is unreachable on this backend.** The Woo adapter only ever records `incomplete` / `completed` / `canceled`. So `escalation_report` can't be exercised here at all — only the `no_payment_token` dead end, plus `permission_denied` if we force it.
3. **Auto-open is https-only.** `CheckoutHandoff#https?` requires `URI.scheme == "https"`. A `http://localhost:8080` store fails that check even once `links` is populated, so `opened:` will be `false` on plain HTTP. Decide during the run whether that's correct behaviour (probably yes) or whether localhost deserves an exemption.
4. **The CLI never passes `payment_method` to the Woo adapter.** `Resolver`'s WooCommerce entry ([resolver.rb:48](../../portage-ucp/lib/portage/ucp/resolver.rb#L48)) calls `Adapter.new(client:, site_url:, currency:)` — no `payment_method:`, and no `WOOCOMMERCE_PAYMENT_METHOD` in its `env:` map, even though `exe/portage-ucp-woocommerce` reads one. So any `portage buy` that reaches `complete_checkout` raises `"no payment_method configured on this Adapter"`. Dry run is unaffected; completion is blocked until this is wired.
5. **`complete_checkout` posts an incomplete Store API body.** `submit_checkout` sends only `payment_method` + `payment_data`. WooCommerce's `POST /wc/store/v1/checkout` also wants `billing_address` (and `shipping_address`) — expect a 400 naming missing required fields rather than a gateway error.

## Stack

One `docker-compose.yml` under `tmp/woo-local/` (gitignored, not committed):

- `db`: `mariadb:11` — throwaway root password, no volume needed beyond a named one we can `docker compose down -v`.
- `wordpress`: `wordpress:6-apache` on `localhost:8080`, pointed at `db`.
- `wpcli`: `wordpress:cli` on the same network/volume, for scripted setup.

Everything runs over plain HTTP on `localhost`. No TLS in phase 1 — see step 6 for when we need it.

## Setup steps

1. `docker compose up -d db wordpress`, wait for the DB to accept connections.
2. `wp core install --url=http://localhost:8080 --title="Portage Test" --admin_user=admin --admin_password=... --admin_email=...`
3. `wp plugin install woocommerce --activate`. Confirm the Store API answers: `curl -i http://localhost:8080/wp-json/wc/store/v1/cart` should return 200 plus `Cart-Token` and `Nonce` response headers — the two things `Client#store_request` threads on every later call. If those headers are absent, everything downstream is moot and that's finding #1 of the run.
4. Seed products: `wp plugin install wordpress-importer --activate` then import WooCommerce's bundled `sample_products.xml`. That gives both simple and **variable** products — we need at least one variable product to test `Mapper.variant`'s `attributes[].option` join (README caveat #2).
5. Enable a gateway with no external dependency: `wp option update woocommerce_cod_settings '{"enabled":"yes"}' --format=json` (Cash on Delivery, id `cod`). It takes no card data, so it exercises the checkout submit path without a Stripe account. Also set currency/country so totals are deterministic.
6. Generate Admin REST keys. wp-admin's REST API screen is the documented route; scripted, it's an insert into `wp_woocommerce_api_keys` with a `consumer_secret` and the SHA-256 of the consumer key, via `wp eval`. Record the key/secret pair into an untracked `tmp/woo-local/.env`.

## Test ladder

Each rung is only attempted once the one below it passes. Record the actual output of each in the design log, including failures — the point of the run is the observations.

### Rung 0 — credentials
```
WOOCOMMERCE_SITE_URL=http://localhost:8080 \
WOOCOMMERCE_CONSUMER_KEY=... WOOCOMMERCE_CONSUMER_SECRET=... \
  bundle exec rake woocommerce_smoke_test
```
Confirms Basic Auth against the Admin API and that a product comes back. If this fails over plain HTTP, WooCommerce may be refusing Basic Auth on a non-TLS connection — in which case jump to the TLS variant below rather than debugging keys.

### Rung 1 — adapter directly, in isolation
A script (not a spec) against the live site, in order: `search_catalog` → `get_product` on a **variable** product → `create_cart` → `update_cart` → `create_checkout` → `get_checkout`. What to record:

- Does `Client` keep the same `Cart-Token` across calls, i.e. does `create_checkout` actually see the items `create_cart` added? This is the single biggest untested assumption in the client.
- Does `POST /cart/add-item` succeed on the first write, given `Nonce` is only set from the prior `GET /cart` response?
- `Mapper.variant` titles on the variable product: right, or mangled?
- Store API money fields: do `prices.price` / `currency_minor_unit` produce correct minor units through `Mapper`?
- Is the variation id (what `line_item_id_of` picks) the id the Store API's `add-item` accepts? Woo takes `id` + `variation` params; if it rejects a bare variation id, that's a real adapter bug and also explains any Shopify-shaped assumption leaking in.

### Rung 2 — platform detection
`curl -s http://localhost:8080 | grep -ci woocommerce` must be non-zero, then confirm `Resolver.detect_platform` picks WooCommerce off the real homepage body/headers rather than only off our fixtures.

### Rung 3 — `portage buy --dry-run` (the actual ask)
```
WOOCOMMERCE_SITE_URL=http://localhost:8080 \
WOOCOMMERCE_CONSUMER_KEY=... WOOCOMMERCE_CONSUMER_SECRET=... \
WOOCOMMERCE_CURRENCY=USD \
  bundle exec portage buy http://localhost:8080 --query "beanie" --dry-run --json
```
Note the explicit `http://` — `Buy#initialize` prepends `https://` to a bare host, which would fail against a plain-HTTP container.

Pass criteria: `source: "adapter:WooCommerce"`, `browse: true`, `checkout: true`, a real `checkout_id` (the Cart-Token), `checkout_status: "incomplete"`, populated `totals`, and — per the hand-off doc's non-negotiable — **no `handoff` key and no browser opened**, even with `--auto-open` passed and `PORTAGE_NOTIFY_WEBHOOK_URL` set. Verify that negative explicitly: run it a second time with `--auto-open --notify-webhook http://localhost:9999/hook` against a netcat listener and confirm the listener receives nothing.

Also confirm the journal side-effect: `Buy#client_for` passes a real `PurchaseJournal`, so a dry run writes to `~/.portage/journal.jsonl`. Check what it recorded and whether that's what we want for a run that never completes.

### Rung 4 — the `no_payment_token` dead end
Same command, `--yes`, no `--payment-token`, no enrolled default payment method. This is the one hand-off path WooCommerce can actually reach. Expected per expectation #1: `checkout_url: nil`, `handoff: nil`. If so, stop and file the Woo `links` gap — the hand-off feature is untestable on this backend until `Mapper.checkout` emits a checkout URL.

Once `links` is populated (in a follow-up pass), re-run to check: `handoff.url` present, `handoff.opened == false` on plain HTTP (expectation #3), `handoff.notified == true` with a listener on `--notify-webhook`, and the POST body carrying `reason: "no_payment_token"` plus the right `checkout_id`/`source`/`totals`.

### Rung 5 — completion (expected to fail; run it anyway)
`--yes --payment-token dummy` against the `cod` gateway. Expected: `"no payment_method configured on this Adapter"` (expectation #4), since the Resolver never passes one. Wire `WOOCOMMERCE_PAYMENT_METHOD` through the Resolver, re-run, and then capture whatever the Store API says about the missing `billing_address` (expectation #5). Both errors are the point — they're what "unverified against a live site" actually cashes out to.

### Rung 6 — TLS variant (only if needed)
If rung 0 fails on Basic Auth over HTTP, or if we want to exercise `CheckoutHandoff`'s auto-open for real, put Caddy in front with an `mkcert`-issued cert for `woo.local`, add a hosts entry, and re-run rungs 0–4 against `https://woo.local`. Note that `system("open", url)` in a validation run will genuinely open a browser window — expect it, don't run rung 4 with auto-open inside CI.

## Out of scope

- Any fix. This pass produces observations and a list; changes land in a follow-up with their own specs.
- Real payment gateways (Stripe/PayPal). `cod` is enough to reach the Store API's checkout endpoint; confirming `payment_data_key` per gateway is a separate, larger question.
- Committing the Docker stack. It lives untracked under `tmp/woo-local/` this pass; if the run proves useful we can promote it to a `docker/` directory with its own README.
- The other unverified adapters (Wix, BigCommerce, Magento, Etsy). Same method should apply later; WooCommerce is first because it's the only one that self-hosts in a container.

## Done when

Every rung has a recorded outcome, expectations 1–5 are each confirmed or refuted with real output, and `portage-ucp-woocommerce`'s README "Unverified against a live site" section has been rewritten to say what we now actually know — including whatever new caveats the run turns up.
