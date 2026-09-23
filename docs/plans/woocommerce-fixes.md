# WooCommerce adapter fixes

**Status:** Fixes 1–4 landed (see `portage-ucp-woocommerce`'s CHANGELOG and
README "Fixed since this pass"). Fix 5 needed no code change (see below).
This pass added further hardening on top: `Resolver`'s `billing_address`
no longer raises an uncaught `JSON::ParserError` on malformed
`WOOCOMMERCE_BILLING_ADDRESS`, and falls back to `PORTAGE_SHIP_*` when
that env var is unset instead of requiring its own JSON blob.
**Driver:** [`docs/plans/woocommerce-local-validation.md`](woocommerce-local-validation.md) ran the full test ladder against a live Docker WooCommerce install and confirmed five real gaps (folded into [`portage-ucp-woocommerce`'s README](../../portage-ucp-woocommerce/README.md#%EF%B8%8F-verified-against-a-local-install--five-real-gaps-found)). This is the follow-up pass that plan explicitly deferred: fixes, with specs, not just observations.

Local validation stack (Docker WooCommerce, WP 7.1.1 + WooCommerce 11.1.1, TLS via Caddy) is still up at `tmp/woo-local/` — reuse it to confirm each fix live before landing it. `docker compose up -d` in that directory if it's been torn down; `.env` there has working Admin keys and `SSL_CERT_FILE`/`RUBYOPT` values are in the validation plan's rung commands.

## Fix 1 — hand-off can't fire: `Mapper.checkout` never emits `links`

**Where:** [`portage-ucp-woocommerce/lib/portage/ucp/woocommerce/mapper.rb:107`](../../portage-ucp-woocommerce/lib/portage/ucp/woocommerce/mapper.rb#L107) — `Mapper.checkout` hardcodes `links: []`.

**Fix:** `Mapper.checkout` needs the site's checkout page URL. `Adapter#create_checkout`/`#get_checkout`/`#update_checkout`/`#cancel_checkout` already have `@site_url` in scope — thread it into `Mapper.checkout(node, id:, status:, site_url:, order: nil)` and build a `links: [{ "url" => "#{site_url}/checkout/" }]`-shaped entry (match whatever `Buy#checkout_url_of` expects — check `portage-cli/lib/portage/cli/checkout_handoff.rb` for the exact link shape other adapters emit, e.g. Shopify's, and mirror it).

**Caveat to flag in the PR:** `/checkout/` is WooCommerce's *default* checkout page slug, not guaranteed — a store can rename it. There's no Store API field that returns the actual checkout page URL directly. Cheapest correct option: fetch it once via `wp-json/wp/v2/pages` filtered by template, or accept the default-slug assumption and document it as a known limitation (same posture as other "good enough, not exhaustive" calls in this adapter).

**Verify:** rerun rung 4 of the validation plan (`no_payment_token` dead end) — `checkout_url` should now be non-null, and `handoff.url` should be present. `handoff.opened` should still be `false` on the plain-HTTP store (expectation #3, unaffected by this fix) — confirm the hand-off's `https?` check still gates auto-open correctly.

## Fix 2 — CLI swallows the real completion error

**Where:** [`portage-cli/lib/portage/cli/buy.rb:167`](../../portage-cli/lib/portage/cli/buy.rb#L167) — `adapter_flow`'s `rescue LoadError, StandardError; nil`.

**Problem:** Any adapter error past this point — including the very real, very actionable `"no payment_method configured on this Adapter"` — gets silently converted into the generic `"No automated path — visit ... yourself."` message. Confirmed live: piping `--yes --payment-token dummy` through `portage buy` against the local Woo store produced that generic message with zero indication of the actual cause, while calling the adapter directly surfaced `Portage::Ucp::WooCommerce::Error: no payment_method configured on this Adapter` immediately.

**Fix:** Narrow the rescue. `LoadError` (adapter gem not installed) genuinely means "fall through to the generic path" — that's correct and should stay silent-ish (or get a one-line "adapter unavailable" note). But a `StandardError` raised *after* `Resolver.build_adapter` succeeds — i.e. once the adapter is live and actually attempted the call — is a real, surfaceable failure and shouldn't be swallowed into the same bucket as "there's no adapter for this platform at all." Recommended shape: split into `rescue LoadError` (returns `nil`, unchanged) and a separate `rescue StandardError => e` around just the `full_buy`/`catalog_only_adapter` call that re-raises or returns a report carrying `e.message`, distinguishable from the "no platform detected" case.

**Check first:** confirm this blanket rescue isn't there specifically to keep `portage buy`'s top-level flow resilient against a fully broken/misconfigured adapter (e.g. malformed env) crashing the whole CLI. If so, the fix is "log/report the swallowed error," not "stop catching it" — read the surrounding `merge_adapter_checkout_fallback` caller and any existing tests in `portage-cli/spec/` for `adapter_flow` before changing behavior here.

**Verify:** rerun rung 5 (`--yes --payment-token dummy` against `cod`) — expect the CLI's own output (not just a direct adapter call) to surface `"no payment_method configured on this Adapter"` or an equivalent user-visible message, not the generic fallback.

## Fix 3 — `Resolver` never passes `payment_method` to the WooCommerce adapter

**Where:** [`portage-ucp/lib/portage/ucp/resolver.rb:41-42`](../../portage-ucp/lib/portage/ucp/resolver.rb#L41-L42) — the WooCommerce `Platform`'s `env:` map has no `payment_method` entry, unlike `exe/portage-ucp-woocommerce` which does read `WOOCOMMERCE_PAYMENT_METHOD` (check that exe file for the exact env var name and any `payment_data_key` handling alongside it).

**Fix:** Add `payment_method: "WOOCOMMERCE_PAYMENT_METHOD"` to the `env:` hash, and update `build_adapter` (right below, in the same `Platform.new` block) to pass `payment_method: env[:payment_method]` through to `Adapter.new`. Not `required:` — completion-only, same as the exe script treats it (search_catalog/checkout still work without it).

**Verify:** rerun rung 5 with `WOOCOMMERCE_PAYMENT_METHOD=cod` set — `portage buy --yes --payment-token dummy` should now reach the Store API's `/checkout` call and hit Fix 4's `billing_address` error instead of the payment_method error, confirming the wiring (not the endpoint) was the blocker.

## Fix 4 — `submit_checkout` posts an incomplete Store API body

**Where:** [`portage-ucp-woocommerce/lib/portage/ucp/woocommerce/adapter.rb:167-177`](../../portage-ucp-woocommerce/lib/portage/ucp/woocommerce/adapter.rb#L167-L177) — `submit_checkout` posts only `payment_method` + `payment_data`. Confirmed live: `WooCommerce API error (400): Missing parameter(s): billing_address`.

**Fix:** UCP's `complete_checkout` doesn't currently take a billing address as an argument (check `Portage::Ucp::Adapter`'s interface and whatever `portage-cli` collects from the buyer before calling it — likely nothing yet). This is the biggest of the five: it needs either (a) a new parameter threaded from UCP's `complete_checkout` down through every adapter's shared interface (cross-cutting, touches more than this gem), or (b) a WooCommerce-specific stopgap — e.g. `Adapter.new(..., billing_address: {...})` supplied at construction time, same posture as `payment_method:`. Read how Shopify's/other adapters handle buyer address data (if at all) before picking an approach — this may already be a known gap tracked elsewhere in `docs/plans/`.

**Verify:** rerun rung 5 with `payment_method` wired (Fix 3) and a billing address supplied — expect a real order to be created (`order_id` present in the Store API response) rather than a 400.

## Fix 5 — README/docs correction: dry run does not journal (no code fix needed)

**Where:** N/A — this one turned out not to be a bug. `PurchaseJournal#record_checkout` (`portage-ucp-journal/lib/portage/ucp/journal/purchase_journal.rb`) only fires from `Dispatcher`'s `complete_checkout` settle point, by design — a dry run never reaches that point.

**Action:** the validation plan's assumption ("dry run still writes to the journal") was wrong and has already been corrected in the README write-up from the validation pass. No code change — just make sure no other doc/plan repeats the wrong assumption. Skip this one; listed here only so it isn't mistaken for an open item.

## Suggested order

1. Fix 3 (Resolver wiring) — smallest, unblocks testing Fix 2 and Fix 4 for real instead of by construction workaround.
2. Fix 2 (CLI error swallowing) — makes every other fix's failures visible during their own verification, so do it early.
3. Fix 1 (hand-off links) — independent of the others, can land in parallel.
4. Fix 4 (billing_address) — biggest, likely cross-cutting; do last once the others prove the rest of the path works.

Each fix gets its own spec in `portage-ucp-woocommerce/spec/` or `portage-ucp/spec/` (WebMock-stubbed, as existing specs do) *and* a live re-run of the relevant rung from the validation plan before merging — stubs alone are what got the adapter into this state in the first place.
