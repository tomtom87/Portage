# Changelog

Repo-level changes — the workspace, its shared docs, and anything spanning more
than one gem. Each gem keeps its own `CHANGELOG.md` for its own API; look there
for changes to `portage-ucp`, an adapter, the client, or the CLI.

Format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/);
this project is pre-1.0, so APIs may still shift between minor versions.

## [0.9.0] - 2026-09-23

- **New gem: `portage-ucp-webmcp`.** It adds WebMCP as a transport to the
  existing `Adapter` contract, next to classic MCP (stdio, Streamable HTTP)
  and native UCP. It is not a new commerce backend.
  - Inbound: a store's pages register its catalog/cart/checkout tools on
    `document.modelContext`, and each call goes back to the same
    `Mcp::Server`.
  - Outbound: a `portage-ucp-client` transport drives the WebMCP tools of
    any page, through Ferrum, Playwright, Selenium or any JavaScript-
    evaluating callable. The page doesn't have to run Portage.
  - End-to-end specs run the real page scripts in node against the real
    Rack endpoint. They check that WebMCP returns the same documents as the
    in-process Loopback transport.
- `portage-ucp-client`: `get_cart`, `update_cart` and `cancel_cart` work
  again over the loopback and stdio transports. Before, both transports
  dropped `cart_id`. See that gem's changelog.
- **`portage-ucp` 0.9.0: one copy of each decision rule.** `portage-cli`
  kept hand-copied fallbacks of `portage-ucp-decision`'s offer-ranking and
  escalation rules, and ran every spec twice so the copies couldn't drift.
  Both rules now live in core (`Support::OfferRanking`,
  `Support::Escalation`) next to `PolicyGuard`. The gem's `OfferRanking`
  and `EscalationPolicy` wrap them, as `PolicyCheck` wraps `PolicyGuard`,
  and the CLI calls them directly. `portage-cli` and
  `portage-ucp-decision` now require `portage-ucp ~> 0.9`, and every
  lockfile pins `portage-ucp` 0.9.0. `portage buy`'s `decisions:` verdicts
  now report string reasons in-process as well as in `--json`, and
  `confidence` gained a `reason` alongside its `error` detail.
  `Support::Totals.amount` joins them, replacing the `type == "total"`
  lookup copied across `portage-cli`, `Dispatcher` and `ReferenceAdapter`.
  No adapter gem had its own copy.
- **Version bumps for gems whose code changed after their last publish.**
  `publish_all` skips any version already on rubygems.org, so
  `portage-ucp-client` 0.6.1, `portage-cli` 0.6.4 and
  `portage-ucp-woocommerce` 0.2.0 would have been skipped with newer code
  sitting unreleased. `portage-ucp-webmcp` would also have installed
  against the published client 0.6.1, which lacks
  `Transports::UcpWireShape`, and failed on `require`. They are now
  `portage-ucp-client` 0.6.2, `portage-cli` 0.7.0 and
  `portage-ucp-woocommerce` 0.2.1. `portage-cli` and `portage-ucp-webmcp`
  require `portage-ucp-client >= 0.6.2`.

## [0.8.2] - 2026-09-22

- **Anonymous native UCP validated against thirteen unrelated live Shopify
  stores**, not just `catalog.shopify.com` and this project's own dev store.
  Discovery, catalog, multi-line carts and checkout all answer with no token,
  no signature and no approval; a three-variant cart at quantity two returns
  three correctly-totalled lines, and `create_checkout` from it returns
  `requires_escalation` with the store's payment handlers, which is the
  documented no-grant outcome. Design log §43 has the full matrix, including
  the hostile inputs (negative/zero/absurd quantities, bogus variant ids) and
  two limits found with no fix: stores clamp quantity silently and by
  wildly different amounts, and `create_cart` is not idempotent server-side
  even though the client sends the key.
- **An omitted UCP `context` has three outcomes, not the one 0.8.1
  documented.** Of nine stores, three built a correct cart without it, one
  emptied it, and five priced the cart in the market of the *caller's IP
  address*. The gem always sends a context, so nothing regressed — but the
  wrong-currency cart carries no message saying so, which makes it the harder
  failure of the two, and the docs said only "empties the cart". Sending one
  is also necessary rather than sufficient: `mejuri.com` empties a `US`/`USD`
  cart for a product it publishes only to `CA`, while its `search_catalog`
  ignores the context and reports that product available at CAD prices to
  every market. `skills/shop-via-ucp.md` now says so.
- **`portage-cli` 0.6.4 fixes the checkout hand-off pointing at the wrong
  page.** It handed the shopper the first link in the checkout's `links`,
  which on every real store is a policy link — the checkout lives at
  `continue_url`. So the auto-open added in 0.8.1 opened the merchant's
  refund policy. Found by running the flow against third-party stores rather
  than the dev store, which is the only reason it surfaced before release.
- **`portage-cli` 0.6.3 / `portage-ucp-client` 0.6.1**: a store's own refusal
  (out of stock, a rejected line) is reported with the store's sentence and
  `continue_url` instead of crashing `portage buy` with a backtrace holding
  the store's entire error envelope. `Client::ServerError` gained
  `#payload`/`#summary`/`#continue_url`/`#server_messages`.
- `portage-cli` now requires `portage-ucp-client ~> 0.6`; it was pinned
  `~> 0.5` while calling a constant added in 0.6.0.
- **`portage-ucp-woocommerce` 0.2.0 / `portage-ucp` 0.8.1**: same third-party
  validation pass found WooCommerce's hand-off, completion and error
  reporting genuinely broken, not just untested. `Mapper.checkout` always
  built `links: []`, so the checkout hand-off couldn't fire on this backend
  at all; `Resolver`'s WooCommerce entry never threaded `payment_method` or
  `billing_address` through to the adapter, so `complete_checkout` failed
  with neither configured even when both env vars were set; and the Store
  API's `/checkout` 400s without a `billing_address` UCP's own
  `complete_checkout` interface has no parameter for. `Mapper.checkout` now
  takes a required `site_url:` keyword — **breaking for anyone calling
  `Mapper` directly**.
- **`portage-cli`'s `adapter_flow` was hiding a live adapter's own error.**
  It rescued `LoadError` and `StandardError` identically, so a real,
  actionable failure from an installed adapter (e.g. "no payment_method
  configured on this Adapter") surfaced as the same generic "no automated
  path" dead end as a platform with no adapter installed at all. Found
  while validating the WooCommerce fixes above.
- **`portage-ucp-shopify` 0.5.0** fixes catalog reads surfacing products
  that can't be bought: `search_catalog`/`get_product`/`lookup_catalog` now
  read through the Storefront API instead of Admin, which also returns
  `DRAFT`/`ARCHIVED` and unpublished products that `cartCreate` then
  rejects outright. **Breaking for anyone calling `Mapper` directly**:
  `Mapper#scalar_price` is removed and `Mapper#variant` no longer takes a
  `currency` argument, since Storefront returns money as `MoneyV2` objects
  rather than Admin's bare scalar.
- `rake release_check` and `rake publish_all` were broken for every gem with
  a portage dependency — the require smoke-test put only the gem's own `lib/`
  on the load path, so verifying a build failed with `cannot load such file
  -- portage/ucp` against a package that was in fact fine. It now runs that
  require with `GEM_HOME`/`GEM_PATH` pointed at the throwaway install dir.
- jsdelivr caches `@main` for a week, so for days after 0.8.1 the CDN kept
  serving the *old* agent profile — reproducing 0.8.1's own `Tool not found`
  bug against correct code in the repo. Purged, and both `.env.example` and
  `docs/agent-profile.md` now say to purge after every profile change (or to
  pin `@<sha>`).

## [0.8.1] - 2026-09-22

- **Native UCP tool calls against live Shopify stores work.** They were failing
  with `-32602 Tool not found: <name>` on every catalog/cart/checkout call, and
  `0.8.0`'s docs concluded that was a platform-side allowlist with no fix
  available. That was wrong. The cause was this repo's own agent profile:
  catalog is registered per action (`dev.ucp.shopping.catalog.search`,
  `dev.ucp.shopping.catalog.lookup`), the profile declared the coarse
  `dev.ucp.shopping.catalog` — because `Generate::AgentProfile` reused
  `Portage::Ucp::Capabilities::CATALOG.name`, right for our own server's
  manifest and wrong for an agent profile — and a server resolves an agent's
  tool registry from exactly those ids, so it resolved none. Versions were
  `"1"` where the registry uses spec revisions, and `services` was `{}`, which
  declares an agent that speaks no service. `portage generate agent-profile`
  now emits the real ids at `2026-08-25` with the shopping service declared,
  and the checked-in `portage-cli/agent-profile/agent-profile.json` is
  regenerated. Verified live, anonymously — no token, no signatures, no
  approval — against `catalog.shopify.com`, a third-party storefront, and this
  project's own dev store: search → cart → checkout, stopping at the
  `continue_url`.
- **`portage-ucp-client` 0.5.0**: sends the UCP `context` object
  (`address_country`/`address_region`/`postal_code`/`currency`/`language`) on
  catalog, cart and checkout calls. Without it a store scopes the call to no
  market and silently drops every cart line, answering
  `merchandise_out_of_stock` for a product its own `search_catalog` just
  returned as available — a plausible wrong answer rather than an error.
  `Session` takes `context:` on those methods and `cart_id:` on
  `create_checkout`; `Transports::{Loopback,Stdio}` drop both, since they hand
  arguments to this gem's own flat-argument server.
- **`portage-cli` 0.6.1**: new `Portage::Cli::BuyerContext` builds that context
  from `PORTAGE_SHIP_COUNTRY`/`_REGION`/`_POSTAL_CODE` plus `PORTAGE_CURRENCY`
  and `PORTAGE_LANGUAGE`, and `buy`/`find` pass it on every call.
- Docs corrected rather than deleted: `docs/ucp-tool-gating-investigation.md`
  and `docs/agent-profile.md` now lead with the real cause and keep the
  original allowlist reasoning below it, including why the `get_order`
  "forbidden" tell was misread. `complete_checkout` remains genuinely
  case-by-case; nothing else does.

## [0.8.0] - 2026-09-17

- `portage-ucp` bumps to 0.8.0 for a **breaking** manifest shape change:
  `Manifest#to_h` now nests everything under a top-level `ucp` object, renames
  `ucp_version` to `version`, and keys `capabilities` by capability name,
  matching what live UCP stores actually serve (confirmed against Shopify's
  `2026-08-25` rollout across 35+ storefronts) instead of the flat shape this
  gem invented. Anything reading a Portage-served manifest by the old
  top-level keys needs updating; `Rack::ManifestEndpoint` and
  `skills/serve-via-ucp`'s `verify.sh` both did, and are fixed here.
- `portage-ucp-client` bumps to 0.4.0 for the same lesson on the outbound
  side: `Transports::Http` was sending every tool call flat and unwrapped, and
  real stores 422 it — arguments belong nested under a capability key, with a
  `meta.ucp-agent.profile` URL the store fetches to verify who's calling.
  `Http` now builds that shape, callers must pass `meta: { agent_profile: }`,
  and two new errors (`MissingAgentProfileError`, `UnsupportedWireShapeError`)
  say so plainly rather than letting a bare 422 through. `Loopback`/`Stdio`
  are unchanged.
- `portage-cli` bumps to 0.6.0 for `portage generate agent-profile` (writes
  the UCP agent-identity document the above needs; the CLI's own is checked
  in and published to a stable URL by a new GitHub Pages workflow, which is
  where `PORTAGE_AGENT_PROFILE` points by default), clear `find`/`buy`
  failures when that profile is missing or rejected, and a fix for `buy`
  sending a catalog product's own id as the purchasable line item — Shopify's
  cart takes a `ProductVariant` GID, so every live `portage buy` failed with
  "Invalid id" until now.
- `portage-ucp-shopify` bumps to 0.4.4, `portage-ucp-journal` to 0.1.1, and
  `-wix`, `-woocommerce`, `-bigcommerce`, `-magento`, `-etsy`, `-instagram` to
  0.1.4: pin-only releases, no behavior change, so each installs alongside
  `portage-ucp` 0.8.0 (their published `~> 0.7` pin is pessimistic and
  excludes it).
- Repo: `rake publish_all` builds, smoke-tests, and pushes every gem whose
  version isn't on rubygems.org yet, in dependency order, reusing
  `release_check`'s build-from-the-gem's-own-directory verification — the
  0.7.1 postmortem's checklist, now a task instead of a README paragraph.
  README gains a CLI quick start and a walkthrough at
  `docs/cli-usage-tutorial.md`.

## [0.7.1] - 2026-09-16

- No behavior change in any gem. 0.7.0's `portage-ucp`, `portage-cli`,
  `portage-ucp-shopify`, `portage-ucp-client`, `portage-ucp-wix`, and the
  five smaller adapters were all built and pushed to RubyGems with `gem
  build` run from the workspace root instead of each gem's own directory —
  every gemspec's `spec.files = Dir["lib/**/*.rb", ...]` resolved against
  the wrong working directory, so every 0.7.0-line package shipped empty
  (no `lib/`). All ten 0.7.0-line versions have been yanked; this release
  repackages the exact same code, correctly, one patch version up from
  each. Release checklist now builds from each gem directory and
  smoke-tests `require` after install (`rake release_check[gem_dir]`, see
  README's "Releasing a gem").

## [0.7.0] - 2026-09-16

- `portage-ucp` bumps to 0.7.0: cryptographic AP2 mandate signature
  verification (`Ap2::MandateSignature`, real ECDSA against a JWK trust-anchor
  set, plus a `require_signature:` fail-closed option on `MandateGuard`,
  closing the gap 0.6.0's shape-only mandate validation left open), a
  cross-process idempotency race fix (`FileStore#fetch_or_store`, atomic
  temp-file-plus-rename persistence, a poisoned-file rescue, reaped per-key/
  per-session locks, and a new `Configuration#idempotency_provider`), a
  `Rails::Railtie` + `rails g portage:ucp:install` generator, opt-in
  OpenTelemetry span emission alongside the existing JSON logging, and
  `Mcp::Server.build(journal:)` — naming the seam `portage-cli` now wires a
  real journal through (see below) — plus `#each_record`/`#all` on
  `TransactionLog`/`OrderLedger`. See `portage-ucp`'s own `CHANGELOG.md`.
- `portage-cli` bumps to 0.5.0 for `portage-console` (a read-only IRB REPL
  over the local transaction/order/journal stores), `portage generate
  adapter` (scaffolds a new adapter gem), `portage doctor` (sanity-checks a
  seller's `Portage::Ucp.configuration`), and wiring a real
  `PurchaseJournal` into `portage buy`'s own-store loopback path — that path
  previously left the journal empty even though `portage-console` above
  could read one. New runtime dependency on `portage-ucp-journal` (`~> 0.1`).
- `portage-ucp-shopify` bumps to 0.4.2 for a fix to `GraphqlError` crashing
  instead of surfacing Shopify's real message when `errors` comes back as a
  bare string, plus a new live-store buyer-journey spec.
- `portage-ucp-client`, `portage-ucp-wix`, `portage-ucp-bigcommerce`,
  `-woocommerce`, `-etsy`, `-magento`, and `-instagram` all take pin-only
  patch releases (no behavior change) so each can install alongside
  `portage-ucp` 0.7.0: their previously-published `~> 0.6` pin is
  pessimistic and excludes 0.7.x. `portage-ucp-journal`'s `portage-ucp`
  dependency (development-only, not a runtime dependency) also widens to
  `~> 0.7` in its gemspec, published as 0.1.0.

## [0.6.0] - 2026-09-15

- **Fix:** `portage-ucp-woocommerce`, `-bigcommerce`, `-magento`, `-etsy`, and
  `-instagram` all bump to 0.1.1 for a standing bug, unrelated to the
  `portage-ucp` work below and predating it: each `Mapper.product` built a
  `Portage::Ucp::Product`/`Variant` with keywords (`price:`, `available:`)
  `dev.ucp.shopping.catalog`'s schema-conformance work removed in favor of
  `price_range:`/a real `variants:` array (see that work's own changelog
  entries, back when only `portage-ucp-shopify` and `-wix` got their mappers
  migrated) — every real `search_catalog`/`get_product` call against these
  five adapters raised `ArgumentError: missing keyword: :price_range`. Each
  adapter's `#search_catalog`/`#get_product` also returned a bare
  `Array<Product>`/`Product` instead of the `CatalogSearchResult`/
  `ProductDetail` wrapper the `Adapter` contract documents, which would have
  failed UCP schema validation even once the first bug was fixed. Caught by
  running the core gem's schema-validation conformance examples (added
  earlier for the payment-enrollment slice below) against every adapter,
  not just Shopify/Wix's specs, which asserted the same wrong shape their
  mappers produced.

- `portage-ucp` bumps to 0.6.0 for the §22/§33-§35 payment-enrollment and
  signature-verification slice: `PaymentEnrollmentGuard` (validates every
  `create_payment_enrollment`/`get_payment_enrollment` response — breaking,
  raises `InvalidPaymentEnrollmentError` on a malformed one), an AP2 mandate
  shape (`Ap2::PaymentMandate`/`Ap2::MandateGuard`, shape-only — no
  cryptographic verification), a `Store`/`FileStore` extraction under
  `Support::TransactionLog`/`Support::OrderLedger` so either can be backed
  by something other than a file, `app.portage-ucp.payment_method` /
  `saved_address` / `shopper_data` extensions, `Dispatcher.new(journal:)`
  wiring for the new `portage-ucp-journal` gem, RFC 9421 HTTP Message
  Signature verification (`Security::Signature`,
  `Rack::SignatureVerification`) for inbound requests, and
  `Confirmer::Webhook` — an out-of-band approval path for the confirmation
  gate (POST + poll, or a caller-supplied `wait:` callback), alongside the
  existing `Terminal`/`AutoApprove` confirmers. See `portage-ucp`'s own
  `CHANGELOG.md`.
- `portage-ucp-journal` is a new gem (0.1.0): a buyer-side purchase journal
  plus the injectable `Store` abstraction `portage-ucp`'s own
  `Store`/`FileStore` split now mirrors.
- `portage-cli` bumps to 0.4.1, `portage-ucp-client` to 0.3.1,
  `portage-ucp-shopify` to 0.4.1, and `portage-ucp-wix` to 0.1.1 — pin-only
  releases (no behavior change) so each can install alongside `portage-ucp`
  0.6.0: their previously-published `~> 0.5` (`~> 0.5` for `-wix`'s 0.1.0)
  pin is pessimistic and excludes 0.6.x. Every other gem's `portage-ucp` pin
  also widens to `~> 0.6` in its gemspec, with no release of its own needed
  beyond what's already covered above.

## [0.5.0] - 2026-09-14

- `portage-ucp` bumps to 0.5.0 for the agentic-payments work (docs/plans/agentic-payments.md):
  `Adapter#create_payment_enrollment`/`#get_payment_enrollment` (card-on-file
  enrollment without the card touching this process), a durable
  `Support::TransactionLog` wired into `complete_checkout` dispatch,
  `PolicyGuard`/`Policy` (per-transaction/rolling caps, velocity, merchant
  allowlist, per-token enrollment scopes), a `Confirmer` gate
  (`Terminal`/`AutoApprove`) run just before dispatch, a durable
  `Support::OrderLedger` snapshot written after settlement, `_meta`
  `ucp-agent.profile` threading alongside the existing `traceparent`
  correlation id, and `Adapter#lookup_catalog(ids:)` for batch product
  fetch by id — see `portage-ucp`'s own `CHANGELOG.md`.
- `portage-cli` bumps to 0.4.0 for `portage payment list/enroll/set-default/
  remove/freeze/revoke` (Keychain / Secret Service / env-var-only storage)
  and `portage policy show/set`, both driving the new `portage-ucp` policy
  and enrollment capabilities.
- `portage-ucp-client` bumps to 0.3.0 for `Session#create_payment_enrollment`/
  `#get_payment_enrollment` and an optional `meta:` kwarg threaded through
  every transport.
- `portage-ucp-shopify` bumps to 0.4.0 for `Adapter#lookup_catalog(ids:)`,
  fetching several known product ids in one round trip via the Admin API's
  `nodes(ids:)` field.
- Every adapter gemspec and `portage-cli` widen their `portage-ucp` pin to
  `~> 0.5` (and `portage-cli`'s `portage-ucp-client` pin to `~> 0.3`) for the
  capabilities above; only `portage-ucp`, `portage-ucp-shopify`,
  `portage-ucp-client`, and `portage-cli` have ever been published to
  RubyGems.

## [0.4.0] - 2026-08-28

- `portage-cli` bumps to 0.3.0 for `portage compare` (§22's "find this same
  item elsewhere" mode) and `portage history` (local purchase/search log),
  plus a fix for a `search_catalog` envelope-unwrapping bug that had been
  producing malformed offers against every real store since 0.2.0 — see
  `portage-cli`'s own `CHANGELOG.md`.
- `portage-ucp` bumps to 0.4.0 for the `app.portage-ucp.reorder` capability,
  per-request correlation ids threaded through `Dispatcher`/`Mcp::Server`/
  `CheckoutState` for observability, and a widened `Observability::REDACTED_KEYS`
  covering the PII fields that actually flow through logged events — see
  `portage-ucp`'s own `CHANGELOG.md`.
- `portage-ucp-shopify` bumps to 0.3.1 to widen its `portage-ucp` dependency
  pin from `~> 0.3` to `~> 0.4` — no code change of its own. Every other
  adapter gemspec and `portage-ucp-client` got the same pin widened, but
  none has published a version yet, so there's no install-breakage to fix
  for them beyond keeping the constraint correct ahead of their first
  release.
- `portage-cli` and `portage-ucp` are the only two gems in this release with
  behavior changes; `portage-ucp` and `portage-ucp-shopify` remain the only
  two gems ever published to RubyGems.

## [0.3.0] - 2026-08-27

- All seven adapter gems now run the core gem's conformance kit against their
  real `Adapter` through a real `Dispatcher`
  (`spec/portage/ucp/<platform>/conformance_spec.rb`), closing the follow-up
  design-log §17 left open when the kit shipped. No adapter needed
  body-matching stubs: the kit's reachable surface stops at `create_checkout`.
- Core gem's `~> 0.2` dependency pin widened to `~> 0.3` in every adapter,
  `portage-cli`, and `portage-ucp-client` gemspec.
- `portage-ucp` and `portage-ucp-shopify` both bump to 0.3.0 — see each
  gem's own `CHANGELOG.md` for `Support::Retry`, `Support::SessionLock`, the
  Shopify metadata_field config DSL, and the Shopify GraphQL shape fixes
  driving the bump. `portage-cli` and `portage-ucp-client` are unchanged and
  stay at 0.2.0.

## [0.2.0] - 2026-08-21

### Added

- `~/.portage/` — the first state anything here keeps outside the project
  directory. `stores.yml` is the store allowlist you curate; the CLI writes
  `discovery-cache.json` to remember which origins answered
  `/.well-known/ucp`, so a URL-less search doesn't re-probe the same hosts on
  every run. Both are the CLI's, and both are documented in
  [`portage-cli`](portage-cli/README.md).
- Search-backend credentials as configuration that belongs to no adapter:
  `BRAVE_SEARCH_API_KEY`, `GOOGLE_CSE_KEY` / `GOOGLE_CSE_CX`, and
  `PORTAGE_STORES`. The per-adapter variables in the root README's
  Requirements table decide which platforms the CLI can buy from; these decide
  which stores it can propose in the first place, so they sit outside that
  table.
- Root `CHANGELOG.md` (this file) — every gem already had one, the workspace
  itself didn't.
- `docs/walkthrough.md` and `docs/well-known-ucp.md`: the agent-buys-a-snowboard
  walkthrough and the `/.well-known/ucp` rationale, moved out of the root README
  so it opens on how to install and run the thing.
- A `## License` section in every adapter gem's README — all seven shipped a
  `LICENSE` file without pointing at it.
- `docs/design-log.md` §15: how the CLI finds a store when the user has no URL,
  and why the search step uses documented APIs rather than a scraped results
  page. Ships alongside `portage find` in `portage-cli`.

### Changed

- Root README's gem table describes both ways into the CLI — `portage buy
  <url>` when you know the shop, and `portage find --query "..."` when you
  don't.
- Root README follows the `bundle gem` section order: Installation and Usage
  come first, then the gem table, then everything else. The table of contents
  now matches the rendered order (Requirements had been listed last and rendered
  second).
- Root README's Requirements section is a per-adapter env-var table linking each
  adapter's own README, instead of restating credential setup those READMEs
  already own.
- Every README names its how-to-run section `## Usage`, replacing the mix of
  `Quickstart` (core, client) and `Using the adapter directly` (adapters).

## [0.1.0] - 2026-08-14

- Initial release: ten gems, published to RubyGems. See each gem's own
  `CHANGELOG.md` for what it ships, and the [design log](docs/design-log.md)
  for the rationale behind the split.
