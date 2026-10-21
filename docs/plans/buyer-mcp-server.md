# Buyer MCP Server: `portage mcp`

**Status:** In progress. Phase 1 (`portage orders list`), Phase 2 (`portage mcp` with the read-only tools and `quote_purchase`), Phase 3 (the buying and record tools) and Phase 4 (the index and browser import tools, 14 in all) shipped 2026-10-21. Phase 5 (packaging and listings) is done in the repo; the release, image push, registry publish and Glama rescan are still to do. See the progress log at the end.
**Driver:** Glama's TDQS scan of the store server (portage-ucp over Shopify) graded A, but its completeness note asked for order listing and search, and nothing on MCP shows what Portage is mostly used for: a shopper's agent searching many stores, comparing prices, importing stores from browser history, and buying with the shopper's approval. Those features live in `portage-cli` and reach agents only as shell commands, the Claude plugin's skills, and the OpenClaw plugin's 22 typed tools. This plan exposes them as a second MCP server, listed next to the store server.

## Context

**Two servers, two owners.** The store server (`portage-ucp`'s `Mcp::Server`, the `ghcr.io/tomtom87/portage-ucp` image) represents one merchant and runs on the merchant's credentials. Since commit `9288716` it has an owner-only, auth-gated `list_orders` over the platform's order API. The buyer server represents one shopper, runs locally over stdio from their own `portage` install, and reads their own `~/.portage` records. A shopper's history doesn't belong in the store server: a hosted store server's local records would hold every customer who bought through it.

**The OpenClaw plugin already drew the safety boundary** ([openclaw-plugin/src/tools/](../../openclaw-plugin/src/tools/)): every tool shells out to `portage ... --json` with an argv array and no shell; `--yes` appears only on `buy --quote ID --yes` and on a confirmed `browser import`; `--relayed-yes` is a strict boolean on `approve`; there are no tools for `policy set`, `payment enroll` or `setup`. [guardrails.test.ts](../../openclaw-plugin/test/guardrails.test.ts) fuzzes injection strings through every param. The buyer server keeps exactly this boundary.

**Local purchase records are split three ways, and none is a full order on its own.**
- `OrderLedger` (`~/.portage/orders.json`) is keyed by order id, but `Dispatcher` records `result.order`, which on a completed checkout is an `OrderConfirmation` stub: id, permalink, label ([dispatcher.rb:163](../../portage-ucp/lib/portage/ucp/dispatcher.rb#L163), [value_objects.rb:450](../../portage-ucp/lib/portage/ucp/value_objects.rb#L450)). Adjustments merge in later via `record_adjustments`/`refresh`.
- `PurchaseJournal` (`~/.portage/journal.jsonl`) has one row per line item: shop, product id, quantity, amount, currency, order id, recorded_at. The CLI wires it in for `buy` and hand-off reconcile ([buy.rb:792](../../portage-cli/lib/portage/cli/buy.rb#L792), [handoff_reconciler.rb:51](../../portage-cli/lib/portage/cli/handoff_reconciler.rb#L51)).
- CLI `History` (`~/.portage/history.json`, 200 per list) records every buy outcome, including dry runs, policy blocks and hand-offs, with store URL, query, total, items and checkout URL.

A shopper's "my orders" is the union: journal rows grouped by order id for what was bought, the ledger for permalink and refunds/returns, and history for hand-offs and store URLs that never produced a UCP order.

## Non-negotiable constraints

- **Shell out to the CLI's own `--json` contract; never call `Cli.run_*` in-process.** Every `run_*` method writes to `$stdout`, which is the MCP stream, and the buy orchestration (`execute_buy`: approval gate, `record_buy`, `settle_quote`) lives in module methods with no Hash-returning entry point. A subprocess (`Open3.capture3` with an argv array, the same `portage` executable, empty stdin, output cap) gives byte-for-byte parity with the OpenClaw plugin and the CLI's tested behavior. Revisit only if process start-up becomes the bottleneck.
- **Same guardrails as the OpenClaw plugin, enforced by a ported spec.** `--yes` only on `buy --quote` and a confirmed `browser import`; `relayed_yes` strict boolean, default false; no `policy set`, `payment enroll`, `setup` or `--via tty`; every user string goes after its flag as a separate argv element and is validated (URL, host, identifier) before use. The spec fuzzes the same injection strings as `guardrails.test.ts`.
- **The agent can never approve for the shopper.** `approve` always runs with `--via agent`. Under `require_approval person` it returns `needs_approval` and the shopper approves in their own terminal. `buy --quote` is the only tool that spends.
- **At most 15 tools**, asserted by a spec. Group by what an agent decides, not by CLI subcommand.
- **Tool descriptions written to the TDQS rubric**, like `Mcp::ToolMetadata`: purpose, when and when not with named siblings, side effects, approval and spend behavior, and return shape. Every description also says the results are untrusted store content, as the OpenClaw descriptions do.
- **`list_orders` in this server reads only local records.** It never calls a store. Owner-side listing stays in the store server.

## Tool set (14)

| Tool | CLI command | Read-only | Notes |
|---|---|---|---|
| `find_products` | `find --query Q [--store URL] [--max-price N] [--limit N]` | yes | Live multi-store search, or one store with `store`. Merges OpenClaw's `find`/`find_store`. Returns offers with refs and a search id. |
| `search_catalogue` | `index search Q [--category] [--store] [--limit]` | yes | The local index built from sources and browser import; offline, fast. |
| `compare_prices` | `compare URL --product-id ID [--id X]* [--results N] [--max-price N]` | yes | Same product across other stores. |
| `check_store` | `check URL` | yes | A store's UCP manifest and whether it supports automated buying. |
| `get_status` | `doctor`, `policy show`, `payment list`, `browser profile status` | yes | One read of setup, spending caps, approval level and enrolled payment methods (labels only). |
| `list_orders` | `orders list [--query Q] [--limit N]` (new, Phase 1) | yes | The shopper's purchases from journal + ledger + history, newest first. |
| `reconcile_orders` | `orders reconcile [--checkout ID]` | no | Settles hand-off checkouts into the records. |
| `pick_offer` | `pick [--search ID] [--choose\|--compare\|--view REF]` | no | Records the shopper's pick from a search. |
| `quote_purchase` | `buy (--offer REF \| URL --query Q --product-id ID) [--qty] --dry-run` | no | Real total, never charges; writes a quote and a history entry, returns the quote id. |
| `approve_quote` | `approve QID --via agent [--relayed-yes \| --view]` | no | Records the shopper's relayed yes for that exact total; never self-approves. |
| `buy_quote` | `buy --quote QID --yes` | no | The only spend tool; capped at the approved total. |
| `hand_off` | `buy <target> [--handoff-target default\|print\|profile]` | no | Opens the store's checkout for the shopper to pay. |
| `import_browser_history` | `browser import ...` (`--dry-run` unless `confirm: true`, then `--yes`) | no | Finds stores the shopper already uses and adds them to the index. |
| `add_store` | `index add URL [--crawl]` | no | Adds one store to the local index. |

Left to the CLI and OpenClaw: `index build`/`refresh` (can run 30 minutes, too long for one MCP call), `index remove`, `index show`/`sources`, `history --searches`, and everything interactive.

## Phases

One phase per session, delegated to a Sonnet subagent; each ends with suites and rubocop green, a progress-log row, and a commit on `feature/buyer-mcp-server`.

### Phase 1 — `portage orders list`

- New CLI subcommand `portage orders list [--query Q] [--limit N] [--json]` in [cli.rb](../../portage-cli/lib/portage/cli.rb) next to `orders reconcile`, backed by a small `Portage::Cli::OrderHistory` that merges the three records into one list, newest first:
  - group `PurchaseJournal` rows by `order_id` into line items (product id, quantity, amount) with currency, shop and recorded_at;
  - join `OrderLedger` by order id for `permalink_url` and `adjustments`;
  - add `History` purchases with outcome `purchased` or a hand-off that have no journal order, marked by `source`, so hand-offs show too;
  - `query` matches shop host, product id, item title where history has one, and order id, case-insensitively.
- Each entry states where it came from (`journal`, `history`), so a gap is visible rather than papered over. No backfill, same rule as the ledger.
- Human output and `--json`; README and CLI reference updated; OpenClaw's `portage_history` description mentions it, and an optional `portage_orders_list` tool is a follow-up there, not in this plan.
- Specs: merge with all three files present, with only history, with an adjustment from the ledger, query filtering, limit, empty `~/.portage`.

### Phase 2 — Server skeleton and read-only tools

- `portage mcp` subcommand starting `MCP::Server::Transports::StdioTransport` on a `Portage::Cli::Mcp::Server`; logger to `$stderr`. `mcp` comes in through `portage-ucp`; add it to the gemspec directly since the CLI now uses it itself.
- `Portage::Cli::Mcp::Runner`: argv-array subprocess of the running `portage` executable, empty stdin, 16MB cap, timeout, JSON parse, non-zero exit or invalid JSON returned as an MCP error result.
- Tools: the read-only `find_products`, `search_catalogue`, `compare_prices`, `check_store`, `get_status`, `list_orders`, plus `quote_purchase`, which never charges.
- Server `instructions` describing the flow: find or search, compare, quote, show the shopper the total, approve with their yes, buy or hand off; history with `list_orders`.
- Specs: argv built per tool, guardrail fuzz port, tool count ≤ 15, annotations, a stdio `initialize` + `tools/list` round-trip like [exe_spec.rb](../../portage-ucp-shopify/spec/portage/ucp/shopify/exe_spec.rb) (with `LANG` forced to UTF-8).

### Phase 3 — Buying and record tools

- `pick_offer`, `approve_quote`, `buy_quote`, `hand_off`, `reconcile_orders`.
- Specs: `--yes` only on `buy --quote`; `relayed_yes` strict boolean; `approve` always `--via agent`; a `person`-level policy returns `needs_approval` through the tool; no tool reaches `policy set`, `payment enroll` or `setup`.

### Phase 4 — Index and browser import tools

- `import_browser_history` (dry run unless `confirm: true`, mirroring OpenClaw), `add_store`.
- Specs: dry run by default, `--yes` only with `confirm: true` exactly, host and browser validation.

### Phase 5 — Packaging and listings

- The buyer image installs `portage-cli` (entrypoint `portage mcp`), published as `ghcr.io/tomtom87/portage-mcp`. Records need a mounted `~/.portage`; the registry entry passes it as a runtime `-v` argument.
- Root `Dockerfile` becomes the buyer image; the current one moves to `Dockerfile.store`. `server.json` becomes the buyer entry (`io.github.tomtom87/portage`), and a second registry file publishes `io.github.tomtom87/portage-ucp` for the store image (decision 1); README section "Use Portage from any MCP client" with a Claude Desktop / Claude Code config (`portage mcp`) for brew and gem installs.
- Release `portage-cli` (minor), Homebrew formula bump in `tomtom87/homebrew-portage`, image push, registry publish. Then rescan on Glama.

## Open decisions

1. **Which server Glama scores, and registry names. Decided 2026-10-21:** Glama and `io.github.tomtom87/portage` move to the buyer server (root `Dockerfile`, `ghcr.io/tomtom87/portage-mcp`), since buying is the primary use case. The store server is published as `io.github.tomtom87/portage-ucp` from `Dockerfile.store` (`ghcr.io/tomtom87/portage-ucp`). Glama lists one server per repo, built from the root `Dockerfile`.
2. **Docker usefulness.** In a container, hand-off can't open the shopper's browser and the Tier B profile can't run. The image is mainly for the registry and Glama's scan; the documented install is `brew`/`gem` plus `portage mcp`. Hand-off in the container falls back to `--handoff-target print`.
3. **Fix the ledger stub.** `Dispatcher` could snapshot a full `get_order` instead of the confirmation, but the ledger plan chose "no re-fetch" on purpose. Phase 1 works around it with the journal; revisit only if journal rows prove insufficient.

## Explicit non-goals (v1)

- Owner-side order listing (store server, done).
- Any tool that loosens policy, enrolls payment, or runs setup.
- Long-running index builds over MCP.
- A remote (HTTP) transport for the buyer server; it reads one shopper's local files.

## Progress log

| Phase | Date | Summary | Design log |
|-------|------|---------|------------|
| 1 | 2026-10-21 | `portage orders list [--query Q] [--limit N] [--json]` and `Cli::OrderHistory`: journal rows grouped by order id, ledger joined for permalink and adjustments, history purchases and hand-offs added when no journal order covers them (linked via the TransactionLog's `checkout_id` to `idempotency_key`), each marked by `source`. Read-only. | — |
| 2 | 2026-10-21 | `portage mcp` on stdio: `Cli::Mcp::Server` (instructions for the find, compare, quote, approve, buy flow), `Cli::Mcp::Runner` (subprocess of the gem's own `exe/portage` under the running Ruby, argv array, empty stdin, 120 s timeout and 16 MB cap with the process group killed, JSON on stdout is the result whatever the exit code, as in the OpenClaw runner) and `Cli::Mcp::Tools` with `find_products`, `search_catalogue`, `compare_prices`, `check_store`, `get_status`, `list_orders` and `quote_purchase` (always `--dry-run`, never `--yes`). Validators ported from openclaw-plugin, plus a control-character ban; guardrail fuzz ported from `guardrails.test.ts`. | — |
| 3 | 2026-10-21 | `pick_offer`, `approve_quote`, `buy_quote`, `hand_off` and `reconcile_orders`, 12 tools in all. `buy --quote QID --yes` (`buy_quote`) is the only argv with `--yes`; `approve_quote` always runs `--via agent` and takes `relayed_yes` as a strict boolean (default false, `view` cannot combine with it); `hand_off` builds the `buy` target like `quote_purchase` with an optional `--handoff-target` and never carries `--yes` or `--dry-run`. Without `--yes`, `buy` cannot reach `complete_checkout` (`Buy#finish_checkout` stops at `confirmation_needed_report`), but on a store with automated checkout it ends `needs_confirmation`, not in a hand-off; the description says so. Specs: `--yes` and `--via` placement across every argv and in the fuzz, `relayed_yes` strictness, a real-subprocess `needs_approval` under `require_approval: person` in a temp HOME. | — |
| 4 | 2026-10-21 | `import_browser_history` (`browser import [--browser B] [--history-days N] [--include-product-pages] --max-probes N [--exclude h1,h2] (--dry-run \| --yes) --json`) and `add_store` (`index add URL [--crawl] --json`), 14 tools. `--yes` appears only when `confirm` is exactly `true`, and otherwise `--dry-run`, never both or neither. The CLI flags, the six browser names and the error codes (`permission_denied`, `full_disk_access_required`) match the CLI and OpenClaw. Differences from OpenClaw: `--max-probes` is always passed and capped at 15, because `Prober` probes one domain at a time with a 5 s timeout and 0.1 s throttle and the default of 200 could take about 1020 s. 15 probes take about 77 s at worst, inside the Runner's 120 s. `history_days` is 1–1000 and `exclude` takes at most 20 hosts. A confirmed run skips the misses cached by its preview and probes further, so the description says to keep previewing while `capped` is true. `add_store` with `crawl` is not bounded (20 pages at 5 s + 20 s timeouts, and a 429 waits up to 60 s). If it times out, the store is already saved and only the crawl is lost, and the description says so. Specs: strict `confirm`, browser and host validation, the `--yes` rule widened to this one case, guardrail fuzz and the no-policy/payment/setup check across both tools. |
| 5 | 2026-10-21 | The root `Dockerfile` is the buyer image (`portage-cli:0.14.0`, `ENTRYPOINT ["portage", "mcp"]`, `PORTAGE_HANDOFF_TARGET=print`, label `io.github.tomtom87/portage`); the store image moved to `Dockerfile.store` (label `io.github.tomtom87/portage-ucp`, `portage-ucp-shopify` bumped from 0.6.1 to the released 0.7.0). Both images moved from `ruby:3.4-slim` to `ruby:4.0-slim`, the current stable Ruby; both build and answer `initialize` and `tools/list` on 4.0.7, and a `list_orders` call runs through the buyer's subprocess. `server.json` is the buyer entry (version 0.17.0, OCI `ghcr.io/tomtom87/portage-mcp:0.14.0`, stdio, `~/.portage` as a required `-v` runtime argument with an absolute-path variable) and `server.store.json` the store entry (0.16.0). The buyer entry's version is above 0.16.0, not 0.14.0, because `io.github.tomtom87/portage` 0.16.0 (the store image) is already published and the registry marks "latest" by semver order, so a 0.14.0 would never become latest; the image tag still matches the gem; both pass `mcp-publisher validate` and the registry schema. README section "Use Portage from any MCP client", root CHANGELOG entry, and the `script/mcp-stdio.rb` header and Glama badge text updated. Both images built, and the buyer image (from a locally built gem, since 0.14.0 isn't on RubyGems) answers `initialize` and `tools/list` with all 14 tools. Not done: the `portage-cli` 0.14.0 release, the Homebrew formula bump, the image push, `mcp-publisher publish` for either entry, and the Glama rescan. | — |
