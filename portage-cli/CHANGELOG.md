# Changelog

All notable changes to this project are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.0.0/); this project is
pre-1.0, so APIs may still shift between minor versions.

## [0.5.1] - 2026-09-16

- No behavior change — 0.5.0 was built and pushed with `gem build` run from
  the workspace root instead of this gem's own directory, so `spec.files =
  Dir[...]` resolved against the wrong working directory and packaged an
  empty gem. 0.5.0 has been yanked; 0.5.1 repackages the exact same 0.5.0
  code correctly.

## [0.5.0] - 2026-09-16

- Added `portage-console` — a read-only IRB REPL over the local
  `TransactionLog`/`OrderLedger`/`PurchaseJournal` stores (design-log §22
  item 6, `Portage::Cli::Console`). `transactions`/`find_transaction`/
  `transactions_since`, `orders`/`find_order`, and `journal`. Every result
  passes through `Portage::Ucp::Observability.redact`. Deliberately a local
  REPL, not the admin/web panel design-log §16 also describes — see the
  README's Console section for why. New runtime dependency on
  `portage-ucp-journal` (`~> 0.1`).
- `Buy#client_for` now passes a real `Portage::Ucp::Journal::PurchaseJournal`
  (file-backed, `~/.portage/journal.jsonl`) into `Client.for_adapter` — the
  own-store loopback path used by `portage buy` against your own store now
  actually records to the purchase journal, closing the gap `portage-console`
  above depends on: `journal` was empty on this path because nothing passed
  `journal:` through it (design-log §37/§38).
- Added `portage generate adapter` — scaffolds a new adapter gem (gemspec,
  Gemfile, Rakefile, rubocop config, lib entrypoint, version file, an
  `Adapter` subclass with every capability method stubbed by reflecting off
  `Portage::Ucp::Adapter`'s real method signatures, and a conformance spec),
  modeled on `portage-ucp-etsy`.
- Added `portage doctor` — sanity-checks a seller's
  `Portage::Ucp.configuration` (authenticator/rate-limiter left at
  unconfigured fail-safe defaults, no signing keys/payment handlers
  configured, adapter capabilities only half-implemented).

## [0.4.1] - 2026-09-15

- No behavior change — widens the `portage-ucp` dependency pin to `~> 0.6`
  so this gem can install alongside `portage-ucp` 0.6.0 (the pessimistic
  `~> 0.5` pin published with 0.4.0 excludes it).

## [0.4.0] - 2026-09-14

- Added `portage payment list/enroll/set-default/remove/freeze/revoke` —
  card-on-file storage so `buy`'s `--payment-token` dead-end can fall back to
  a stored default (`@payment_token ||= PaymentMethods.default`) instead of
  requiring a fresh token on every call (docs/plans/agentic-payments.md
  Phase 1). Storage picks macOS Keychain / Linux Secret Service (`secret-tool`,
  D-Bus session required) / a headless `PORTAGE_PAYMENT_TOKEN`-only tier, in
  that order, with no homegrown fallback store. `enroll` is a browser handoff
  to a gateway-hosted setup page (the new `app.portage-ucp.payment_enrollment`
  capability in `portage-ucp`) — no raw card number ever reaches this
  process.
- Added `portage payment enroll --scope-merchant/--scope-max-amount/
  --scope-currency` — binds a Phase 2 per-token policy scope at enrollment
  time, written to `Portage::Ucp::Policy` keyed by the same `token_ref`
  `PolicyGuard` derives from the token at charge time.
- Added `portage policy show/set` — manages the Phase 2 policy file's
  top-level caps/velocity/allowlist (`Portage::Ucp::Policy`), checked by
  `PolicyGuard` on every `complete_checkout`.
- Widened the `portage-ucp` dependency pin from `~> 0.4` to `~> 0.5` and the
  `portage-ucp-client` pin from `~> 0.2` to `~> 0.3` — this release's
  `Policy`/`PolicyGuard`/`TokenRef` and `Session#create_payment_enrollment`
  calls only exist from those versions on.

## [0.3.0] - 2026-08-28

- Fixed: `find` and `buy` were treating `search_catalog`'s wire envelope
  (`{"ucp" => ..., "products" => [...]}`) as the product list itself —
  `Array(session.search_catalog(...))` wrapped the whole envelope Hash into a
  single-element array instead of unwrapping `"products"`, so every offer
  built from it was malformed against any real store. `Portage::Cli::CatalogProducts.from`
  now unwraps the envelope (and the own-store adapter's raw
  `CatalogSearchResult`) before either command touches the result.
- `portage compare <url> --product-id ID` (`Portage::Cli::Compare`, §22's
  "find this same item elsewhere" mode) — resolves a named product, then runs
  `find`'s own candidate-discovery/probe/rank pipeline against its title.
  Every offer carries a `match:` tier (`confirmed`/`likely`/`unconfirmed`)
  based on shared barcode/sku/`--id` identity, the origin store is excluded
  by host, and `--results` truncates after ranking. Catalog-price only — no
  `create_checkout` against candidate stores. Recorded to `portage history`
  as a search.
- `portage history` — local purchase/search history (`Portage::Cli::History`),
  logged automatically to `~/.portage/history.json` on every `find`/checkout-
  reaching `buy`. `list` (`--purchases`/`--searches`, `--limit`, `--json`) and
  `clear` (same scoping flags) subcommands. Separate from `ProbeCache`, which
  remembers hosts, not actions.

## [0.2.0] - 2026-08-21

- `PORTAGE_SHIP_*` env vars (`Portage::Cli::ShippingProfile`) — configure a
  default shipping address for `portage buy`'s own-store adapter-loopback
  path, the same way adapter credentials already live in env. `portage buy`
  auto-picks the cheapest priced option per fulfillment group once an address
  is submitted; there's no interactive rate picker, since the CLI drives one
  automated purchase rather than a conversation. The native UCP session path
  (a third-party store over stdio/HTTP) isn't wired yet — no real UCP server
  to verify a `fulfillment` wire shape against.

## [0.1.0] - 2026-08-14

- Initial pre-release. `portage buy <url>` — native UCP discovery first,
  adapter fallback only when this process already has that platform's own
  credentials.
- `portage find --query "..."` — find UCP stores that stock something without
  knowing a URL, via an allowlist, DuckDuckGo, Brave, or a Google Programmable
  Search engine, then probe each candidate for `/.well-known/ucp` and search
  the survivors' catalogs. Probe results are cached in
  `~/.portage/discovery-cache.json`.
- `portage buy` with no URL runs that search and buys the offer you pick.
  `--yes` alone won't buy from a search result: the merchant has to be named by
  `--store` or an interactive pick.
- `portage buy --product-id ID` buys exactly that product instead of whatever
  the catalog search ranks first.
