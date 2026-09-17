# Changelog

Repo-level changes — the workspace, its shared docs, and anything spanning more
than one gem. Each gem keeps its own `CHANGELOG.md` for its own API; look there
for changes to `portage-ucp`, an adapter, the client, or the CLI.

Format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/);
this project is pre-1.0, so APIs may still shift between minor versions.

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
