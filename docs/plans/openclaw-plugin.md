# OpenClaw Native Plugin

**Status:** phase 4 done
**Branch:** `openclaw-plugin`
**Driver:** Portage ships to OpenClaw today only as a skill on ClawHub (`@tomtom87/portage-buy`), so an OpenClaw agent has to put `portage` shell commands together from the skill text. A native OpenClaw plugin gives the agent typed tools with JSON Schema parameters over the same CLI, ships both skills inside it, and adds OpenClaw's own tool gating on top of Portage's spending policy.

## Context

- OpenClaw native plugins are TypeScript ESM packages: an `openclaw.plugin.json` manifest (`id`, `name`, `description`, `categories`, `contracts.tools`, `toolMetadata`, `activation`, `configSchema`), a `package.json` with an `openclaw.extensions` entry and an `openclaw` peer dependency, and an entry module built with `definePluginEntry` from `openclaw/plugin-sdk/plugin-entry` that calls `api.registerTool({ name, description, parameters, outputSchema?, execute })`. Optional tools (the user opts in) are registered with `{ optional: true }` and listed in `toolMetadata.<name>.optional`. Docs: https://docs.openclaw.ai/plugins/building-plugins, https://docs.openclaw.ai/tools/plugin.
- Publishing: `clawhub package publish tomtom87/portage`, installed with `openclaw plugins install clawhub:tomtom87/portage`. Also installable from npm, git, or a local path (`--link`).
- The CLI is the only engine. Every tool runs `portage <subcommand> ... --json` with `execFile` (argument array, never a shell), parses stdout as JSON, and returns it as both `details` and a text block. Exit codes are not errors on their own: the CLI reports outcomes (`needs_approval`, `quote_changed`, ...) in JSON with non-zero exits; only unparseable output or a spawn failure is a tool error.
- The skills (`plugins/buy/skills/buy`, `plugins/buy/skills/shop-research`) stay the single source of truth for flow and judgement. The plugin bundles copies at build time and adds one short OpenClaw-specific skill mapping each CLI step to its tool.

## Non-negotiable constraints

1. **The user approves every payment.** No tool takes `--yes` on a URL or `--offer` path. The only buying tool is `portage_buy_quote(quote_id)`, which runs `buy --quote ID --yes --json`; the CLI itself refuses unless the quote is approved under the user's `require_approval` policy.
2. **`--relayed-yes` only after the user said yes.** `portage_approve` takes `relayed_yes: boolean` (default false); its description says it must only be true after the user explicitly approved that exact total in chat.
3. **No tool can loosen spending controls or touch credentials.** Not exposed at all: `policy set`, `payment enroll|remove|revoke|freeze|set-default`, `history clear`, `setup` (interactive), `generate`, `--payment-token`, `--via`, proxy flags, `--decision-backend`, `--min-confidence`. Never read `~/.portage/.env`, `policy.json` or `quotes/`.
4. **Product and store text is untrusted data.** Tool descriptions say so; results are passed through, never interpreted by the plugin.
5. **Buying tools are optional (opt-in).** Read-only tools are on by default; `portage_dry_run`, `portage_approve`, `portage_buy_quote`, `portage_handoff`, `portage_pick` (it can open the browser), `portage_browser_import` and index-mutating tools are `optional: true`.
6. **CLI version gate.** Plugin checks `portage --version` once (cached) and returns a clear upgrade message below the minimum (`portage-cli` 0.12.0).

## Tool surface

| Tool | CLI | Default |
|---|---|---|
| `portage_doctor` | `doctor --json` | on |
| `portage_find` | `find --query Q [--max-price N] [--limit N] --json` | on |
| `portage_find_store` | `find --store URL --query Q [--max-price N] --json` | on |
| `portage_check` | `check URL --json` | on |
| `portage_compare` | `compare URL --product-id ID [--id V...] [--results N] [--max-price N] --json` | on |
| `portage_index_search` | `index search Q [--category] [--store] [--limit] --json` | on |
| `portage_index_show` | `index show [--stores\|--products] [--page] [--per-page] --json` | on |
| `portage_index_sources` | `index sources --json` | on |
| `portage_history` | `history list [--purchases\|--searches] [--limit] --json` | on |
| `portage_orders_reconcile` | `orders reconcile [--checkout ID] --json` | on |
| `portage_policy_show` | `policy show --json` | on |
| `portage_payment_list` | `payment list --json` | on |
| `portage_browser_profile_status` | `browser profile status --json` | on |
| `portage_pick` | `pick [--search ID] [--choose\|--compare\|--view REF] --json` | optional |
| `portage_dry_run` | `buy --offer REF [--qty] --dry-run --json` or `buy URL --query Q --product-id ID [--qty] --dry-run --json` | optional |
| `portage_approve` | `approve QUOTE_ID [--relayed-yes\|--view] --json` | optional |
| `portage_buy_quote` | `buy --quote ID --yes --json` | optional |
| `portage_handoff` | `buy ... --handoff-target default\|print\|profile [--wait] --json` (exact flags per skill's hand-off section) | optional |
| `portage_index_add` / `portage_index_remove` / `portage_index_build` / `portage_index_refresh` | `index add\|remove\|build\|refresh ... --json` | optional |
| `portage_browser_import` | `browser import --dry-run --json`, or `--yes` when `confirm: true` | optional |

Final names and parameters are settled in phase 1 against `portage --help` and the skills.

## Config (`configSchema`)

- `portageBin` (string, default `portage` on PATH)
- `timeoutSeconds` (number, default 120; `index build` and `--wait` get their own longer default)
- `minCliVersion` is a constant, not config.

## Phases

### Phase 1: scaffold, runner, read-only tools
- `openclaw-plugin/` package: `package.json`, `openclaw.plugin.json`, `tsconfig.json`, `src/index.ts`, `src/runner.ts` (execFile, timeout, JSON parse, version gate), `src/tools/*.ts`.
- All "on" tools from the table.
- Tests (vitest) against a fake `portage` script that records argv and prints canned JSON: argument building, no-shell, timeout, non-zero exit with JSON = result, garbage output = error, version gate.
- `npm run build`, `npm test`, `npm run typecheck` green.

### Phase 2: buying tools and guardrails
- Optional tools: pick, dry_run, approve, buy_quote, handoff, index mutations, browser import.
- Tests that pin constraints 1–3: no tool can emit `--yes` outside `buy --quote`, `--relayed-yes` only when `relayed_yes: true`, forbidden flags never appear for any input (including injection attempts like `"--yes"` as a query).

### Phase 3: skills and polish
- Build step copies `plugins/buy/skills/{buy,shop-research}` into `openclaw-plugin/skills/`; manifest declares the skills.
- New `skills/portage-openclaw/SKILL.md`: maps each CLI step in the buy flow to its tool, tells the agent to prefer tools over shell.
- Tool descriptions tuned; `outputSchema` for the common outcomes; package README.

### Phase 4: docs, release wiring, publish prep
- Root README "Other agents" OpenClaw bullet, mkdocs page, CHANGELOG entry.
- Rakefile: version check that the plugin version tracks the buy plugin version; `npm pack` dry run.
- Hand-off note for the user to publish to ClawHub from the `tomtom87` account (`clawhub login`, `clawhub package publish tomtom87/portage --dry-run`, then for real).

## Progress log

| Phase | Date | Commit | Notes |
|---|---|---|---|
| 1 | 2026-10-01 | this commit | `openclaw-plugin/` scaffold, runner (execFile, no shell, timeout, version gate 0.12.0), 13 read-only tools, 70 vitest tests against a fake `portage`. Tool names and CLI mapping unchanged from the table; `portage_history` takes `kind` (purchases or searches). Real SDK `openclaw@2026.9.7` is the devDependency and types compile unshimmed (`registerTool` needs `label`). Its preinstall guard demands Node >=24.16, so the package `.npmrc` sets `ignore-scripts=true` (types only). `typebox` 1.3.34 is a runtime dependency. Not exercised against a live OpenClaw gateway; `api.pluginConfig` confirmed in the types, not in the docs. Strings starting with `-` are rejected rather than relying on `--` (OptionParser). |
| 2 | 2026-10-01 | this commit | 10 optional tools (`src/tools/buying.ts`, `src/tools/indexing.ts`), all `optional: true` in the registration and in `toolMetadata`/`contracts.tools`; 99 vitest tests in total (29 new), `test/guardrails.test.ts` fuzzes all 23 tools with injection strings and pins constraints 1-3. Params: `portage_pick` (`search`, one of `choose`/`compare`/`view`), `portage_dry_run` and `portage_handoff` (`offer`, or `store` + `query` + `product_id`; `qty`; handoff adds `target` default/print/profile, `wait`, `wait_timeout` like 30m), `portage_approve` (`quote_id`, `relayed_yes` default false, `view`), `portage_buy_quote` (`quote_id`), `portage_index_add` (`url`, `crawl`), `portage_index_remove` (`host`), `portage_index_build`/`refresh` (`sources`, `dry_run`), `portage_browser_import` (`browser`, `history_days`, `include_product_pages`, `max_probes`, `exclude`, `confirm`). Deviations from the table: `--yes` is also spelled once for `browser import` (only when `confirm: true`; otherwise `--dry-run`), as the table says; hand-off takes no `agent:NAME` target (it needs per-agent approval in the user's config) and never `--yes`; `index build|refresh` omit `--queries` and `--export` (they read and write arbitrary paths), `browser import` omits `--profile-root`. New `ToolSpec.timeoutFor` gives `--wait` hand-offs the CLI's wait ceiling plus a minute (30m default, so 31m); `index build|refresh` get a fixed 30m via `timeoutSeconds`; both are constants, not config. Ids and refs are validated as plain tokens (`ident`), hosts and `--sources` names likewise, `relayed_yes`/`confirm` only accept a real boolean. No `sideEffecting` manifest flag yet. |
| 3 | 2026-10-01 | this commit | `scripts/copy-skills.mjs` (optional target dir; run first by `npm run build`) copies `buy` and `shop-research` into `skills/` (gitignored; `skills` is in package.json `files`); hand-written `skills/portage-openclaw/SKILL.md` is committed and never touched. SDK ground truth: manifest field is `skills: string[]` ("skill directories, relative to the plugin root"; docs do not say whether an entry is a parent or a single skill dir, so it is `["skills"]`, the parent, matching the extraDirs-style merge; unverified on a live gateway). `outputSchema?: TSchema` (TypeBox) on `registerTool`, describing `details` and validated after tool hooks, so the schemas (`src/tools/outputs.ts`) are all-optional, nullable, `additionalProperties: true` and also accept the plugin's `{ error }`; set on find, find_store, check, compare, doctor, pick, dry_run, approve, buy_quote, handoff. `toolMetadata.<name>.sideEffecting` confirmed in the SDK (manifest-only: `registerTool` options have no such field), set on all 10 optional tools; `ToolSpec.sideEffecting` mirrors it and a test pins it. Id prefixes verified against the CLI: `qt_` + 12 hex (`quotes.rb`), `of_` + 6 hex (`find.rb`), searches `se_`. Tool descriptions tuned; package README. 123 vitest tests (24 new). |
| 4 | 2026-10-01 | this commit | Docs: root README "Other agents" gets an OpenClaw plugin bullet (next to the existing ClawHub-skill one), new `docs/skills/openclaw-plugin.md` (nav "Skills" and llms.txt sections, links the package README rather than repeating its tool tables), CHANGELOG `[Unreleased]` entry. Rakefile: `openclaw:version_check` (package.json `version` must equal `plugins/buy/.claude-plugin/plugin.json`), `openclaw:pack_check` (`npm run build`, then `npm pack --dry-run --json`, parsed; fails unless `dist/*`, `openclaw.plugin.json` and `skills/{buy,shop-research,portage-openclaw}/SKILL.md` are listed), `openclaw:release_check` runs both and is invoked by `release_check[gem]` and at the top of `publish_all`, before any push. `package.json` (and the lockfile) were 0.1.0 against buy 0.10.0, so both are now 0.10.0; `openclaw.plugin.json` carries no version. Output schemas: new `historyOutput` for `portage_history` (CLI source `portage-cli/lib/portage/cli.rb` `run_history_list`: always `{ purchases: [], searches: [] }`, the unrequested kind empty; entry fields from `cli/history.rb`). Review found a real mismatch: `doctor --json` prints a bare array of findings (`{ check, message, level, details? }`, `cli.rb` `report_doctor`), not an object, so the old object-only `doctorOutput` would have failed validation on every real result; it is now a union of that array and the loose object (the one schema that is not a top-level object, so the "top-level object" test skips it). `check` and `compare` gained the real fields (`url`, `recommended_gem`, `index_hint`, `live_probe`; `search_id`, `query`, `candidates`, `stores`, offer `match`) and `compare` dropped the invented `results`/`products`; both stay all-optional, nullable and open. `findOutput` still lists an invented `products`, left alone as out of scope (harmless: optional). Unverified: a top-level `anyOf` outputSchema against a live gateway (the SDK types `outputSchema` as any `TSchema`), `mkdocs build --strict` (see report), and ClawHub publish, which is the user's step: `clawhub login`, `clawhub package publish tomtom87/portage --dry-run`, then for real, from the `tomtom87` account. |
