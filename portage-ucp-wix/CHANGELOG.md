# Changelog

All notable changes to this project are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.0.0/); this project is
pre-1.0, so APIs may still shift between minor versions.

## [Unreleased]

- Fixes a `NoMethodError` at launch: `exe/portage-ucp-wix` handed the
  server `Server.build(adapter:).start`, but `Server.build` returns a plain
  `MCP::Server` (mcp gem 0.25.0), which has no `#start` — only
  `MCP::Server::Transports::StdioTransport#open` reads stdio frames. The exe
  now calls that directly, matching `portage-ucp-etsy`'s exe. Adds
  `spec/portage/ucp/wix/exe_spec.rb`, which runs the exe as a real
  subprocess and pipes it a JSON-RPC `initialize` + `tools/list` handshake
  to prove it actually starts and answers requests.

## [0.1.4] - 2026-09-17

- No behavior change — widens the `portage-ucp` dependency pin to `~> 0.8`
  so this gem can install alongside `portage-ucp` 0.8.0 (the `~> 0.7` pin
  published with 0.1.3 is pessimistic and excludes it).

## [0.1.3] - 2026-09-16

- No behavior change — 0.1.2 was built and pushed with `gem build` run from
  the workspace root instead of this gem's own directory, so `spec.files =
  Dir[...]` resolved against the wrong working directory and packaged an
  empty gem. 0.1.2 has been yanked; 0.1.3 repackages the exact same 0.1.2
  code correctly.

## [0.1.2] - 2026-09-16

- No behavior change — widens the `portage-ucp` dependency pin to `~> 0.7`
  so this gem can install alongside `portage-ucp` 0.7.0 (the pessimistic
  `~> 0.6` pin published with 0.1.1 excludes it).

## [0.1.1] - 2026-09-15

- No behavior change — widens the `portage-ucp` dependency pin to `~> 0.6`
  so this gem can install alongside `portage-ucp` 0.6.0 (the pessimistic
  `~> 0.5` pin published with 0.1.0 excludes it).

## [0.1.0] - Unreleased

- Initial pre-release. Wix adapter against the Stores (catalog) and eCommerce
  (cart, checkout, order) REST APIs.
