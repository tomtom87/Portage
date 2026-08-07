# Changelog

Repo-level changes — the workspace, its shared docs, and anything spanning more
than one gem. Each gem keeps its own `CHANGELOG.md` for its own API; look there
for changes to `portage-ucp`, an adapter, the client, or the CLI.

Format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/);
this project is pre-1.0, so APIs may still shift between minor versions.

## [Unreleased]

### Added

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

- Root README follows the `bundle gem` section order: Installation and Usage
  come first, then the gem table, then everything else. The table of contents
  now matches the rendered order (Requirements had been listed last and rendered
  second).
- Root README's Requirements section is a per-adapter env-var table linking each
  adapter's own README, instead of restating credential setup those READMEs
  already own.
- Every README names its how-to-run section `## Usage`, replacing the mix of
  `Quickstart` (core, client) and `Using the adapter directly` (adapters).

## [0.1.0] - Unreleased

- Initial pre-release: ten gems, none yet published to RubyGems. See each gem's
  own `CHANGELOG.md` for what it ships, and the [design log](docs/design-log.md)
  for the rationale behind the split.
