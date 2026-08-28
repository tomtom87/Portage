# Changelog

Repo-level changes — the workspace, its shared docs, and anything spanning more
than one gem. Each gem keeps its own `CHANGELOG.md` for its own API; look there
for changes to `portage-ucp`, an adapter, the client, or the CLI.

Format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/);
this project is pre-1.0, so APIs may still shift between minor versions.

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
