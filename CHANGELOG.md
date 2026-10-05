# Changelog

Repo-level changes — the workspace, its shared docs, and anything spanning more
than one gem. Each gem keeps its own `CHANGELOG.md` for its own API; look there
for changes to `portage-ucp`, an adapter, the client, or the CLI.

Format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/);
this project is pre-1.0, so APIs may still shift between minor versions.

## [Unreleased]

- **README: `shop-research` is on ClawHub.** The OpenClaw bullet said it wasn't published yet; it links to the `@tomtom87/portage-shop-research` listing now.

## [0.17.0] - 2026-10-05

- **Release set:** `portage-ucp` 0.12.0, `portage-cli` 0.13.0, `portage-ucp-shopify` 0.6.0, `portage-ucp-woocommerce` 0.3.0, `portage-ucp-wix`, `portage-ucp-bigcommerce`, `portage-ucp-magento` and `portage-ucp-instagram` 0.2.0, plus the `buy` plugin and the OpenClaw plugin `@tomtom87/portage` 0.10.5. Mostly the over-engineering cleanup: dead public methods and constants removed (minor bumps, each one marked **breaking** in its gem's changelog), duplicated helpers shared, and `portage browser import` reading history through the `sqlite3` gem instead of the `sqlite3` CLI. Fixes: `Security::Signature` answers a malformed trusted JWK with a 401 instead of a 500, and `payment enroll`'s own-store fallback finds the session again and follows homepage redirects. The `buy` plugin drops its raw-UCP direct-checkout fallback (see below). Dependency ranges are unchanged; `portage-cli` still takes `portage-ucp` `~> 0.11`. `portage-ucp-client`, `portage-ucp-webmcp` and `portage-ucp-etsy` changed only in docs, comments or internals, so they stay unreleased. The ClawHub listings are published separately.

- **Security: the `buy` skill no longer has a raw-UCP direct-checkout fallback.** Found by ClawHub's security audit of the `portage-buy` skill 0.10.4, which flagged its "No CLI available" section (Description-Behavior Mismatch and Context-Inappropriate Capability, both medium): with `portage` missing, it had the agent create and pay a store's checkout over raw UCP/MCP itself (`references/raw-ucp.md`), outside the CLI's spending policy, approval and checkout-mismatch checks the rest of the skill relies on. That section now tells the agent to ask the user to install or upgrade `portage` and stop, and never to drive a store's endpoint, cart, checkout or payment with a shell, web fetch or browser, the same stop the OpenClaw plugin's copy already had. `references/raw-ucp.md` and its docs page are gone; buying over raw UCP stays in the standalone `shop-via-ucp` skill. The OpenClaw plugin's build no longer has a file to leave out, and a test checks the source skills carry no direct-checkout path. The `buy` plugin and the OpenClaw plugin move to 0.10.5 for the republish.

- **One shared `examples/portage_ucp.rb`, in `portage-ucp`.** The seven adapter gems each carried a byte-identical copy (apart from the `bundle exec` line in a comment). The single copy now lives at `portage-ucp/examples/portage_ucp.rb`, with a generic usage comment; the adapter exes' header comments, the Etsy and Instagram READMEs, the root README and the adapter docs link to it on GitHub, and the Etsy and Instagram `exe_spec`s load it from there. The files were never in a gem's `files` list, so no gem contents change.

- **Retired four finished plans from `docs/plans/`.** `woocommerce-fixes`, `woocommerce-local-validation`, `openclaw-plugin` and `homebrew-distribution` were done and nothing built on them. They are deleted, and the references to them (the root and gem changelogs, the WooCommerce README, `script/homebrew-formula`, comments in `portage-cli`) now point at permalinks at commit d51200f, where the files can still be read. `docs/design-log.md` has an index entry saying so.

- **One shared RuboCop config for the seven adapter gems.** Their `.rubocop.yml` files were the same apart from each gem's `Metrics/ModuleLength` and `Metrics/ClassLength` exemptions. The shared part now lives in `.rubocop-adapter.yml` at the repo root, and each adapter's `.rubocop.yml` inherits it and keeps only its own exemptions. What RuboCop checks is unchanged.

- **OpenClaw plugin: small tidy-ups, no behaviour change.** `DEFAULT_CONFIG` is no longer exported from `src/config.ts` (nothing imported it), `createRunner` takes the shared `PortageConfig` type, and `scripts/copy-skills.mjs` drops a redundant `mkdirSync` (`cpSync` already creates the target).

## [0.16.2] - 2026-10-01

- **Release set:** `buy` plugin 0.10.4 and the OpenClaw plugin `@tomtom87/portage` 0.10.4, for the ClawHub security audit fixes below (0.10.3 shipped the runner change on its own). The `buy` and `shop-research` skills are reworded, with no instruction changes. No gem changed.

- **Security: the OpenClaw plugin runs `portage` through OpenClaw's own command helper.** ClawHub's security audit of `@tomtom87/portage` 0.10.2 still reported the runner's `child_process.execFile` call as shell execution (`suspicious.dangerous_exec`). The runner now hands the argument array to `api.runtime.system.runCommandWithTimeout`, the helper OpenClaw gives plugins for running a native command, which always spawns without a shell, so the plugin has no `child_process` code of its own. It still only starts a `portageBin` named `portage`, with the per-call timeout, the 16 MB output cap and the same error messages; output past the cap is now a plain error, and `portage` gets an empty stdin. The helper caps output only from OpenClaw 2026.5.28, so that is the plugin's new minimum (was 2026.3.24). Tests run the runner against OpenClaw's real helper. The package README's safety model and the docs page say so. The plugin and the `buy` plugin move to 0.10.3 for the republish; the `buy` skills change only in their `version`.
- **Security: the `buy` and `shop-research` skills are reworded so ClawHub's audit stops misreading them.** ClawHub's SkillSpector audit of `@tomtom87/portage` 0.10.2 flagged the bundled skills' text, not anything they do: `chmod 600` read as root execution, `~/.portage/.env` followed by a space and the words "access token" read as credential theft, a regex running from "write UI code" to a later `~/.portage` path read as session persistence, and the hard rule's quoted `"ignore previous"` example read as tool-metadata poisoning. The skills now say the file must be readable only by the user (file mode `600`), put the path in backticks in every env var description, call the Etsy and eBay tokens OAuth tokens (and Amazon's an API token), say the payment credential lives in the OS's secure credential store, and describe the injection example instead of quoting it; `requires.config` is a flow list with the same two paths. The `buy` description now triggers only on an explicit buy, order or reorder request (with examples), Portage setup or order tracking, and names what it isn't for, after the audit called its trigger too broad. No instruction changes. The `buy` plugin and the OpenClaw plugin move to 0.10.4 for the republish.

## [0.16.1] - 2026-10-01

- **Release set:** `buy` plugin 0.10.2 and the OpenClaw plugin `@tomtom87/portage` 0.10.2. The OpenClaw plugin now declares the `integrations` category, so its ClawHub listing moves out of Other. The `buy` skills change only in their `version` (the OpenClaw plugin's version follows the `buy` plugin's). No gem changed.

## [0.16.0] - 2026-10-01

- **Release set:** `buy` plugin 0.10.1 and the new OpenClaw plugin `@tomtom87/portage` 0.10.1, whose version follows the `buy` plugin's. The OpenClaw plugin carries the ClawHub security audit fixes below: no raw-UCP direct-checkout fallback in its bundled `buy` skill, and a runner that only starts `portage`. The `buy` plugin's skills change only in their `version` (kept equal to `plugin.json`). No gem changed. Both ClawHub listings are published separately, from the `tomtom87` account.

- **New: an OpenClaw plugin, `openclaw-plugin/` (`@tomtom87/portage`).** A native OpenClaw plugin that gives an agent 23 typed `portage_*` tools over the `portage` CLI (arguments passed as an array, never a shell), where the ClawHub skill left the agent to put `portage` commands together from the skill text. Thirteen read-only tools are on by default; the ten that price, approve, buy, hand off, open a browser or edit the index are opt-in. Portage's own policy still decides every payment: no tool passes `--yes` for a URL or an offer, `portage_approve` relays a yes only when told the user gave it, and policy, payment, `setup` and history clearing are not exposed (guardrail tests pin this). It bundles the `buy` and `shop-research` skills, copied at build time, plus a short `portage-openclaw` skill mapping each buy step to its tool, declares an `outputSchema` for the common results, and needs `portage-cli` 0.12.0 or newer (checked once per session). Its version follows the `buy` plugin's, and `rake openclaw:release_check` (version match plus an `npm pack --dry-run` file check) runs inside `rake release_check` and `rake publish_all`. A docs page, a README bullet and the package README describe it. Not yet exercised against a live OpenClaw gateway, and not yet published to ClawHub.

- **Security: the OpenClaw plugin no longer ships a direct-checkout fallback, and only ever starts `portage`.** Found by ClawHub's security audit of `@tomtom87/portage` 0.10.0. The build's copy of the `buy` skill now leaves out `references/raw-ucp.md` (the "no CLI" fallback, where the agent creates and completes a store's checkout over raw UCP itself, outside Portage's policy, approval and checkout-mismatch checks) and replaces that section with a stop: install `portage`, never drive a store's checkout or payment by hand. `portage-openclaw` (now 0.1.1) says the same. The runner, the plugin's one `child_process.execFile` call, already ran without a shell; it now also refuses any `portageBin` that doesn't name the `portage` executable, and the manifest's config schema carries the same pattern. Tests pin both, and the package README's safety model and the docs page explain the `child_process` use the scan reports. The `buy` plugin's own skill is unchanged.

## [0.15.0] - 2026-10-01

- **Release set:** `portage-cli` 0.12.0 (a checkout mismatch now stops every purchase and every WebMCP hand-off, the opt-in confidence check is hardened and runs before every WebMCP hand-off, and `find --store` searches one store live), `portage-ucp-decision` 0.1.2 (a backend answer that isn't a probability now raises `BackendError`, so the purchase is held) and `buy` plugin 0.10.0 (the hardened decision check, the `shop-research` skill, narrower triggers, and `find --store` re-checks; `plugin.json` and both skills' `version` kept equal). `portage-cli` keeps `portage-ucp` `~> 0.11` and its optional `portage-ucp-decision`. The skills' minimum `portage-cli` stays 0.9.0, with the new features gated on 0.12.0 and the older-install fallbacks kept. No other gem changed, so the docs-only notes in `portage-ucp-client` and `portage-ucp-webmcp` stay unreleased. The ClawHub listing is published separately, at `buy` 0.10.0.

- **The `buy` and `shop-research` skills re-check an index hit with `portage find --store URL --query ...`.** That command now exists (see `portage-cli`'s changelog), so the live re-check searches only the store the hit came from instead of re-running a cross-store `find`. `shop-research` lists it as a read-only command, and both skills fall back to `find --query` when `portage find --help` doesn't list `--store`. The CLI JSON reference, README and local-catalogue plan name the same command.

- **Security: the `buy` skill describes the hardened decision check.** Follows `portage-cli`'s
  and `portage-ucp-decision`'s changes (see their changelogs): an extra priced line is now a
  checkout mismatch, the opt-in confidence check sends an allowlisted checkout summary and
  compares against the approved quote, it also runs before every WebMCP hand-off (a preset's own tool, or a page whose tools build a checkout), and a
  malformed backend answer holds the purchase. The skill now suggests the check for unattended
  buying, says it sends TypeSafe a minimal checkout summary and never the address or payment
  token, and that the user sets `JEV_API_KEY` themselves; it declares `PORTAGE_DECISION_BACKEND`,
  `PORTAGE_MIN_CONFIDENCE` and `JEV_API_KEY` in its OpenClaw `envVars`, and the packaging spec
  now checks `JEV_`/`TYPESAFE_` names too. `references/outcomes.md`, `docs/api/cli-json.md`,
  `docs/plans/system-one-decision-layer.md` and `portage-cli`'s README say so.

- **Security: the `buy` skill no longer describes a fail-open checkout mismatch.** Follows
  `portage-cli`'s change (see its changelog): any checkout mismatch now stops a real purchase
  before payment, with no setting to turn that off. `references/outcomes.md`, the skill's
  dry-run and buy steps, `docs/agentic-flow.md`, `docs/api/cli-json.md` and `portage-cli`'s README
  say so, document the dry run's new `checkout_mismatch: true` flag, and mark
  `PORTAGE_ABORT_ON_CHECKOUT_MISMATCH` deprecated and ignored. The skill drops it from its OpenClaw
  `envVars`. Found by ClawHub's security audit of `portage-buy`. The same stop now covers
  `portage-cli`'s WebMCP hand-off flow (a Shopify page's `proceed_to_checkout`): a mismatched cart
  never reaches checkout or autofill. `references/outcomes.md`, `docs/api/cli-json.md`, and the
  READMEs of `portage-cli` and `portage-ucp-webmcp` say so.

- **`buy` skill: narrower triggers.** The skill's `description` is shorter and says it is for
  shopping, buying, ordering or comparing offers on the user's behalf, not for general questions
  about prices, products or orders not placed through Portage (ClawHub's scan flagged the old
  trigger list as too broad). Each OpenClaw `envVars` description now says the user sets it in
  `~/.portage/.env` and the agent never reads or prints its value.

- **New `shop-research` skill in the `buy` plugin, for questions with no purchase in mind.**
  `plugins/buy/skills/shop-research/` answers what something costs, where to get it, whether
  it's in stock, whether Portage can buy from a store, and what the user ordered through Portage.
  Its "Store details" section adds what's known about any store a lookup touches, only from
  fields the read-only commands return: the offer's `store`, `url` and `source`; `check`'s
  `verdict`, `handoff_only`, `platform`, `webmcp.status` and the manifest's `capabilities` and
  `business`; the index entry's `capabilities`, `sources` and `last_verified`. It never invents a
  field and never vouches for a store.
  It runs only read-only commands (`portage find`, `index search`, `index show`, `check`,
  `pick --view`, `history`, `doctor`), each checked against `portage-cli`'s code, and names the
  mutating ones it must never run, including `orders reconcile`, which settles order records. Its
  description says to switch to `buy` to buy. It carries the product-card rules (an index hit is
  "seen at", never a live price or stock), the untrusted-data rule and the hand-off-only "never
  fetch, scrape or drive" rule, so it stands alone on ClawHub. Its OpenClaw `envVars` are only the
  search and retailer keys it names. `buy`'s description now covers buying only and points to
  `shop-research` for lookups. `buy_skill_frontmatter_spec.rb` checks both skills' frontmatter,
  and that `shop-research`'s command table holds only read-only commands. Documented in a new
  `docs/skills/shop-research.md`, the README's install routes, `docs/skills/buy.md`,
  `docs/agentic-flow.md` and the plugin and marketplace descriptions. Not on ClawHub yet.

- **`shop-via-ucp` is for buying, and a new read-only `browse-via-ucp` is for looking.** ClawHub's
  scan of `buy` flagged broad triggers, and `shop-via-ucp`'s ("find and/or buy something from an
  online store") had the same problem. Its description now covers completing a purchase on the
  user's behalf and points lookups to `browse-via-ucp`. It keeps its three guardrails and gains a
  fourth: never pay for a checkout whose items, quantities, unit prices, currency or total differ
  from what the user approved; stop and ask again with a fresh checkout. The new
  `skills/browse-via-ucp/` reads a store's manifest, searches its catalog, reports the store
  details the manifest publishes (business name, capabilities, policy links) and says whether it
  supports automated buying, calls only read-only tools, never creates, updates or completes a
  cart or checkout, and hands over to `shop-via-ucp` to buy. The `buy` skill's
  `references/raw-ucp.md` gets the same mismatch guardrail. New
  `portage-cli/spec/packaging/ucp_skills_frontmatter_spec.rb` parses every `skills/*/SKILL.md`
  frontmatter and checks the split. Listed in `mkdocs.yml`, a new `docs/skills/browse-via-ucp.md`,
  `docs/ai-agents.md`, `docs/agentic-flow.md`, `docs/index.md`, the README and `CONTRIBUTING.md`.

## [0.14.0] - 2026-10-01

- **Release set:** `portage-cli` 0.11.0 (the SQLite local index, `portage index build --sources storefront_products` to crawl a store's products, `portage index search`, the UCP `product` field on offers, and the whole-taxonomy category classifier) and `buy` plugin 0.9.0 (product cards, and the OpenClaw metadata with `version` in the skill frontmatter, kept equal to `plugin.json`). `portage-cli` gains a `sqlite3` `~> 2.9` dependency and keeps `portage-ucp` `~> 0.11`. The skill's minimum `portage-cli` stays 0.9.0, because it only uses `index` and the `product` field when they are there. No other gem changed, so the docs-only notes in `portage-ucp-client` and `portage-ucp-webmcp` stay unreleased. The ClawHub listing is published separately, at `buy` 0.9.0.

- **README: OpenClaw on ClawHub.** A static "OpenClaw skill" badge in the badge row links to the ClawHub listing (`tomtom87/portage-buy`; ClawHub has no official badge endpoint), and the OpenClaw bullet in "Other agents" now documents `openclaw skills install @tomtom87/portage-buy` and `clawhub install @tomtom87/portage-buy` alongside the manual copy route, replacing "planned but not published". The docs site picks it up through the existing include on `docs/skills/buy.md`. The listing goes live when `buy` 0.9.0 is published.

- **README: Omarchy install steps.** The Omarchy bullet now installs with Omarchy's own helper
  (`omarchy-mise-install gem:portage-cli portage`), says a stock Omarchy needs `sudo pacman -S --needed
  make` first (`gcc` already arrives through `clang`; only `make` is missing), and lists the skill
  directories Omarchy links its own skills into (`~/.agents/skills`, `~/.claude/skills`,
  `~/.codex/skills`). Checked against Omarchy `8b4eae6` and an Omarchy-like Arch container, see
  `docs/plans/local-catalogue.md`.

- **`buy` skill: OpenClaw metadata, one skill.** `plugins/buy/skills/buy/SKILL.md` frontmatter gains `version` (kept equal to `plugins/buy/.claude-plugin/plugin.json`) and a `metadata.openclaw` block: `requires.bins: [portage]`, `requires.config`, a brew `install` spec, `homepage`, and an `envVars` entry (all `required: false`) for every env var the skill and its references name, which is what ClawHub's metadata-mismatch scan checks. A new spec (`portage-cli/spec/packaging/buy_skill_frontmatter_spec.rb`) fails if the frontmatter stops parsing, the version drifts from the plugin, or an env var is named without being declared. README's "Other agents" block gains OpenClaw and Omarchy notes. Nothing is published to ClawHub.

- **`buy` skill: product cards.** A new section on showing offers as product cards from the offer's `product` field (image, title, price or range, store, key options, link), host-agnostic, and on treating `index search` hits (`live: false`, no price) as seeds to re-fetch live. Documented in `docs/api/cli-json.md` and `docs/agentic-flow.md`. Code is in `portage-cli`'s changelog.

## [0.13.0] - 2026-09-29

- **Release set:** `portage-cli` 0.10.0 (`portage check URL [--json]`: can Portage buy from this store, and how), `portage-ucp` 0.11.0 (`Ucp::Check` follows a homepage `<link rel="ucp">` manifest pointer, as `buy` does, and reports `manifest_url`), and `buy` plugin 0.8.0 (a "Can Portage buy from this store?" step using `portage check`, gated on `portage --help` listing it). `portage-cli` now requires `portage-ucp` `~> 0.11`. The docs-only notes in `portage-ucp-client` and `portage-ucp-webmcp` stay unreleased.

- **`portage check`** documented in the `buy` skill, `docs/checking-any-store.md`, the CLI tutorial and `docs/api/cli-json.md`. Code and details are in `portage-cli`'s changelog.

## [0.12.0] - 2026-09-29

- **Release set:** `portage-cli` 0.9.0 (human pick and approve, `docs/plans/human-pick-and-approve.md` Phases 1-3: offer refs and `buy --offer`, priced quotes and `buy --quote` with `quote_changed`, `portage pick`, `portage approve`, product-page viewing and `policy set --require-approval`). Under the default `require_approval: any`, a `buy --yes` without an approved `--quote` now dry-runs and returns `needs_approval` instead of buying; `portage policy set --require-approval off`, run from a terminal, restores the old behaviour. `buy` plugin 0.7.1 names `portage-cli` 0.9.0 as the release that ships `pick` and `approve`. The docs-only `[Unreleased]` notes in `portage-ucp`, `portage-ucp-client` and `portage-ucp-webmcp` stay unreleased: no code changed there.

- **`buy` plugin 0.7.0: the person picks the store and approves the total through `portage`.** The skill's steps 3 and 5 now use `portage pick --json` and `portage approve QUOTE_ID --json`. On `needs_pick` it shows `choices[]` with a link to each product page (Claude Code's `AskUserQuestion` when there is one, else a numbered list) and relays the answer with `pick --choose REF`. It then dry-runs with `buy --offer REF`, shows the total and the product link, and relays a yes with `approve QUOTE_ID --relayed-yes`. Under `portage policy set --require-approval person` it doesn't relay: it asks the person to run `portage approve QUOTE_ID` in their own terminal. It buys with `buy --quote QUOTE_ID --yes` and handles `quote_changed`. `references/outcomes.md` gains `needs_pick`, `picked`, `cancelled`, `needs_approval`, `approved`, `viewed`, `view_refused`, `no_terminal`, `search_not_found`, `offer_not_found`, `quote_not_found`, `quote_used` and `quote_changed`, and the exit codes. It needs the `portage-cli` with `pick` and `approve` (unreleased; see `portage-cli/CHANGELOG.md`), not the released 0.8.0. The docs cover the same: `docs/api/cli-json.md` (`pick`, `approve`, `--via`, quotes, the new outcomes, the policy), `docs/agentic-flow.md` (the loop, tools and checklist), `docs/skills/buy.md`, `docs/cli-usage-tutorial.md`, and the usage banners in both READMEs. **Upgrade note:** under the default `--require-approval any`, a `buy --yes` without an approved `--quote` no longer buys. It dry-runs and returns `needs_approval`. Restore the old behaviour with `portage policy set --require-approval off` from a terminal. `person` raises the bar but isn't a hard guarantee: an agent with a shell can edit `~/.portage/policy.json` or the quote files, or run its own terminal.

- **Stale docs cleanup.** `portage-cli`'s and `portage-ucp-webmcp`'s READMEs no longer say a `webmcp_mapping_unconfirmed` proposal can be passed back. No flag or `Buy` keyword takes one. From the CLI, re-run in a real terminal without `--json` (`--dry-run` is enough) and the approved mapping is saved to `~/.portage/webmcp_mappings.json`. From Ruby, inject `webmcp_mapping_confirm:` or `webmcp_mappings:`, or pass `tool_names:` to `WebMcp.connect`. `docs/well-known-ucp.md` now shows the nested manifest Shopify serves at `"version": "2026-08-25"`, trimmed from a live store's. Cart and catalog are advertised there, so the only gap left is signing. `Client.ucp_section`'s comment no longer says `Portage::Ucp::Manifest` emits the flat shape, and says why the flat fallback stays. `docs/security-hooks.md` and `docs/api/portage-ucp.md` now say that `list_payment_methods` and `list_addresses` skip the authenticator and rate limiter by design, because `oauth_token:` guards them.

- **`buy` plugin 0.6.3, and a strict docs build again.** `references/outcomes.md` now matches `portage-cli` 0.8.0. It drops the `webmcp` import verdict, which the CLI never produces. It says what to do on `webmcp_mapping_unconfirmed`: no flag passes a mapping back, so the user confirms it in their own terminal. `checkout_mismatch` only happens under `PORTAGE_ABORT_ON_CHECKOUT_MISMATCH`, and the payment, policy and confidence gates only run on `--yes`. It also covers which buys `history` records with an `outcome`, `invalid_option`, and exit codes (`handoff_only` exits `1`). The docs site gets a page for each of the skill's reference files, so the skill's own relative links resolve there and `mkdocs build --strict` passes. `docs/api/portage-ucp.md` and `docs/security-hooks.md` now say how `Mcp::Server.build`'s default `Confirmer::Terminal` breaks `complete_checkout` over stdio.

- **Docs site pass.** New home page, a rewritten quickstart, an agentic flow tutorial (the `buy` skill, your own loop around `portage --json` with the approval gate in code, and direct UCP/MCP), and an API reference section: CLI JSON output, `portage-ucp`, `portage-ucp-client`, `portage-ucp-decision`, `portage-ucp-journal` and `portage-ucp-webmcp`, each checked against the source. Fixes the `site_url`, the `portage-ucp-client` discover examples (HTTP needs `meta: { agent_profile: }` and returns hashes), and the claim that AP2 mandates are shape-checked only.

- **README rewrite.** Opens with what Portage does, then installing the `buy` plugin (`/plugin install buy@portage`), adding it to other agents with dotagents or as a plain skill, and a first `find`/`buy --dry-run`. Adds a Safety section, merges the doc map and gem list into one table, syncs the usage banner with `portage --help`, and moves the proxy env-var caveats (corrected against the code) into `docs/proxy.md`. The docs site's buy page now pulls its install steps from the README.

- **`buy` plugin 0.6.2.** The skill's minimum version is now `portage-cli` 0.8.0 (plus `portage-ucp-webmcp` 0.2.0 for the browser profile and autofill), which shipped in 0.11.0. It still checks `portage --help` before using newer commands, so older installs keep working.

## [0.11.0] - 2026-09-29

- **Release set:** `portage-cli` 0.8.0 (Phases 1-7 of
  `docs/plans/buy-skill-and-local-browser.md`: offer sources and the Shopify
  Catalog, categories and routing caps, the local store index and known-stores
  list, browser import, the `setup` wizard, hand-off targets and hand-off-only
  hosts, the Portage browser profile and retailer offer sources),
  `portage-ucp-webmcp` 0.2.0 (WebMCP Phases 1-4: platform presets, schema
  matching, approved checkout autofill), and patch releases of
  `portage-ucp-bigcommerce`, `-etsy`, `-magento`, `-wix` (0.1.5) and
  `-woocommerce` (0.2.2), whose exes crashed at launch. `portage-cli` needs
  `portage-ucp-webmcp` 0.2.0 or newer for its WebMCP paths and treats an
  older install as absent.

- **Docs + `buy` skill release** (`docs/plans/buy-skill-and-local-browser.md`
  Phase 8, the plan's last phase). Documents everything Phases 1-7 shipped —
  offer sources/Shopify Catalog, categories/`Classifier`, the local store
  index (`portage index build/refresh/show/add/remove/sources` and the
  repo's published known-stores list), `portage browser import`, the
  `portage setup` wizard, `--handoff-target default|print|profile|agent:
  <name>`, hand-off-only hosts (Tier C) and the as-is/MIT disclaimer, and
  `portage browser profile init|open|status` — in the root README, the CLI
  reference (`portage-cli/README.md`, single-sourced into the site),
  `docs/cli-usage-tutorial.md`, and a new `docs/skills/buy.md` page (added
  to `mkdocs.yml`'s nav). `skills/shop-via-ucp` now points to the fuller
  `buy` plugin for hosts with a plugin system. `plugins/buy/.claude-plugin/
  plugin.json` bumped to `0.6.1`; the skill states the minimum
  `portage-cli` version its references assume. `docs/design-log.md` gains
  entry 52 on the three tiers and why Tier C is hand-off only (Amazon's
  Conditions of Use and its 2025 suit against Perplexity, and that a
  user-edited host list only ever changes the message — there's no
  automation code for a site without UCP or WebMCP for removing a host to
  unlock). The clean-session `/buy` dry run the plan's own Phase 0/8
  checklist calls for still needs an interactive Claude Code session this
  environment doesn't have — left pending, same as Phase 0's note.
- **Retailer offer sources, hand-off only** (`docs/plans/
  buy-skill-and-local-browser.md` Phase 7 — full change is in
  `portage-cli/CHANGELOG.md`). Five official, opt-in buyer-side retailer
  APIs (Walmart Affiliate, eBay Browse — Buy It Now only, Best Buy
  Products, Etsy Open API v3, Amazon Creators) join `OfferSources`
  alongside `ShopifyCatalog`, each gated on its own key. Every offer they
  return still ends in hand-off — none completes a purchase, and none of
  them is ever written into the local index. Amazon already routed
  through the existing Tier C hand-off-only path; walmart.com/ebay.com/
  bestbuy.com now do too (unconditionally — no adapter, no UCP), and so
  does etsy.com unless the process already has its own Etsy *seller*
  credentials configured, in which case `portage-ucp-etsy`'s existing
  adapter flow still applies. `portage setup` gains an eighth wizard step
  for the five keys; `portage doctor` reports which are active. Open
  question 3 (one gem per retailer vs. one `portage-ucp-retail` gem) is
  resolved: kept in `portage-cli`'s `OfferSources`. `plugins/buy/
  .claude-plugin/plugin.json` bumped to `0.6.0`.
- **Hand-off targets + hand-off-only hosts, and the `buy` skill knows both**
  (`docs/plans/buy-skill-and-local-browser.md` Phase 5 — full change is in
  `portage-cli/CHANGELOG.md`). `portage buy --handoff-target
  default|print|profile|agent:<name>` decides where a dead-end checkout
  URL goes, including an approved external agent invoked by command or
  webhook with the same cart-summary payload `--notify-webhook` sends.
  Amazon (every marketplace) and any host in the user's
  `handoff_only_hosts` config are hand-off only: `portage buy` returns
  `handoff_only` without ever sending that host a request, and `find`/
  `index build`/`browser import` never probe one either. `portage doctor`
  and `portage setup`'s Hand-off step both surface the current target, the
  hand-off-only list and the as-is/no-warranty disclaimer.
  `plugins/buy/skills/buy/SKILL.md`, `references/outcomes.md` and
  `references/handoff-only.md` updated; `plugins/buy/.claude-plugin/
  plugin.json` bumped to `0.4.0`. `claude plugin validate .` and `claude
  plugin validate plugins/buy` still pass.
- **`portage setup` interactive wizard, and the `buy` skill knows it's
  human-only** (`docs/plans/buy-skill-and-local-browser.md` Phase 4 — full
  change is in `portage-cli/CHANGELOG.md`). `portage setup` now runs a
  seven-step wizard on a TTY (shipping, search keys, agent profile,
  browser import, local index, spending caps, hand-off); `doctor`/
  `configure` offer it too, but only on a fresh install with nothing
  configured at all. `--json` or no TTY stays exactly today's read-only
  doctor report either way. `plugins/buy/skills/buy/SKILL.md` now tells
  the agent to suggest the user run `portage setup` themselves rather than
  drive it, and that under `--json`/no TTY it's the same report as
  `portage doctor --json`. `plugins/buy/.claude-plugin/plugin.json` bumped
  to `0.3.1`. `claude plugin validate .` and `claude plugin validate
  plugins/buy` still pass.
- **Browser import (Tier A) and the `buy` skill's `browser import` steps**
  (`docs/plans/buy-skill-and-local-browser.md` Phase 3 — full change is in
  `portage-cli/CHANGELOG.md`). `portage browser import` turns the user's
  own bookmarks and history into shop-domain index entries: allowed
  history/bookmark files only (never password, cookie or autofill stores),
  one `/.well-known/ucp` probe per unknown domain (at most 200), shown to
  the user and saved only on a TTY "y" or an explicit `--yes`, and never
  exported. `plugins/buy/skills/buy/SKILL.md`'s browser-import bullet now
  walks the agent through dry-run → show the list → `--yes` only after the
  user approves, and what to do with a Full Disk Access / permission
  error; `references/outcomes.md` gains a `portage browser import --json`
  table. `plugins/buy/.claude-plugin/plugin.json` bumped to `0.3.0`.
  `claude plugin validate .` still passes.
- **Known-stores list moves into the repo, fetched over jsdelivr**
  (`docs/plans/buy-skill-and-local-browser.md` Phase 2c — full change is in
  `portage-cli/CHANGELOG.md`). `portage-cli/known-stores/{stores,
  products}.json` are committed, same schema as the local index, seeded
  with a real `portage index build --sources shopify_catalog --export`
  run (221 stores, 396 products). Every install fetches them lazily over
  the same jsdelivr `@main` channel `agent-profile.json` already uses,
  caches them under the user's own index, and always lets the user's own
  entries win. `rake agent_profile:purge` generalizes into `rake
  jsdelivr:purge` (covers `known-stores/` too; the old task name still
  works as an alias). `buy` skill's index bullet gets one added sentence
  noting `find` may already have candidates before the user runs `index
  build`; `plugins/buy/.claude-plugin/plugin.json` bumped to `0.2.1`.
- **`buy` skill: covers the new `portage index` commands** (`docs/plans/buy-skill-and-local-browser.md`
  Phase 2b — full change is in `portage-cli/CHANGELOG.md`). `plugins/buy/skills/buy/SKILL.md`'s
  setup section now describes `index build/refresh/show/add/remove/sources`
  concretely (still feature-detected from `portage --help`, since older
  installs won't have it), and notes that the index is untrusted, local-only
  data the user builds and edits themselves. `plugins/buy/.claude-plugin/plugin.json`
  bumped to `0.2.0`. `claude plugin validate .` still passes.
- **`buy` skill and plugin marketplace** (`docs/plans/buy-skill-and-local-browser.md`
  Phase 0, docs/config only). `.claude-plugin/marketplace.json` lists one
  plugin, `buy`, at `plugins/buy`. Its `SKILL.md` is the agent-facing
  interface to `portage`: install check, `doctor`-driven setup, the find →
  dry-run → confirm → buy flow, hand-off (`default`/`profile`/`agent:<name>`/
  `print`), hand-off-only retailers, and the hard rules (no raw card data,
  no browser credential/cookie/autofill reads, no CAPTCHA bypass, untrusted
  page text, confirm-before-buy, no blind retries, private shipping
  details). It detects which commands the installed `portage` supports from
  `portage --help`, so `index`/`browser`/`setup`/`--handoff-target` are used
  only once a later phase ships them. Three references:
  `outcomes.md` (every `--json` outcome), `raw-ucp.md` (driving a store's
  UCP endpoint by hand with no CLI), `handoff-only.md` (Tier C and why).
  `skills/shop-via-ucp` is unchanged for now; it starts pointing to `buy`
  once Phase 8 lands. Both manifests pass `claude plugin validate .`.
- **WebMCP outbound docs** (`docs/plans/webmcp-universal-outbound.md`
  Phase 4, no code change). `portage-ucp-webmcp`'s README documents
  platform presets (`Presets`/`preset:`), the schema-matcher fallback for
  an unrecognized page and its read-vs-mutating confirm rule, and Phase 3's
  opt-in checkout autofill (what it will and won't touch, and
  `Preset#checkout_selectors` as a platform's own fallback); `portage-cli`'s
  README points to `--autofill`/`PORTAGE_WEBMCP_AUTOFILL=approve`. The
  `shop-via-ucp` skill now mentions the WebMCP path (ranks after native UCP
  and before platform adapters when a browser is available, always ends in
  a hand-off, and names the autofill opt-in) instead of only covering
  native UCP/MCP. `docs/design-log.md` gained three entries: Phase 0's
  `nil`-capabilities bug and why the spec double it was hiding behind
  didn't catch it, Phase 1's exact-fingerprint-only matching rule, and
  Phase 3's two "unknown means the unsafe-if-wrong option, not the common
  case" defaults (`headless?`, `checkout_selectors`). This closes the plan
  apart from three still-pending live checks noted in its Progress log.
- The Homebrew formula's `test do` block now checks what `portage doctor
  --json` reports (installed via Homebrew, every bundled adapter loads)
  instead of its exit code, which depends on the user's setup
  (`script/templates/portage.rb.erb`). Takes effect on the next
  `rake homebrew:update`.
- `.env.example` and the install docs point at `~/.portage/.env`, which
  `portage-cli` 0.7.5 loads on startup.

- **Homebrew-first install docs** ([plan](https://github.com/tomtom87/Portage/blob/d51200f/docs/plans/homebrew-distribution.md)
  Phase 4). The README, quickstart, CLI tutorial and `portage-cli` README
  list `brew install tomtom87/portage/portage` first and `gem install
  portage-cli` second, with upgrading, Linux `secret-tool`, and PATH
  shadowing covered. The README now shows the full `portage` usage block
  under the quickstart in place of the shorter "Other CLI commands" list,
  and the docs site's quickstart includes the same block from
  `portage-cli/README.md`. The CLI reference moved under "Getting started",
  above the CLI usage tutorial.
- `.env.example` lists the `PORTAGE_SHIP_*` shipping address,
  `PORTAGE_CURRENCY`/`PORTAGE_LANGUAGE`, and the search-backend keys.
- Fixed three doc links that made `mkdocs build --strict` fail (links from
  `docs/` to files outside it), and refreshed the stale gem version tables.

## [0.10.0] - 2026-09-25

- **Proxy support across every gem** (`docs/plans/proxy-support.md`
  Phases 0-3). Core gains `Support::Connection`, `Support::ProxyConfig`,
  `Support::PassthroughContext` and `Rack::ForwardedRequest`; the CLI gains
  `--proxy*` flags, `PORTAGE_PROXY*` env vars, a `proxy` section in
  `config.json` and proxy checks in `doctor`. The release set is
  `portage-ucp` 0.10.0, `portage-ucp-client` 0.6.3, `portage-ucp-webmcp`
  0.1.1, `portage-ucp-decision` 0.1.1, `portage-cli` 0.7.3,
  `portage-ucp-shopify` 0.5.1 and `portage-ucp-instagram` 0.1.5. Every gem
  that calls the new core APIs now requires `portage-ucp` `~> 0.10`, and
  `portage-cli` requires `portage-ucp-client` `>= 0.6.3`. Their old floors
  let them resolve against published gems that lacked those APIs.
- Documentation only, no code change. Fixes a `NoMethodError`-shaped bug
  repeated in every bundled adapter's `exe/` (`portage-ucp-shopify`/`-wix`/
  `-woocommerce`/`-bigcommerce`/`-magento`) and in the root README's
  "Usage" snippet: each called `.start` on the plain `MCP::Server`
  `Mcp::Server.build` returns, but that class (mcp gem 0.25.0) has no
  `#start` — only `MCP::Server::Transports::StdioTransport#open` reads
  stdio frames. See each affected gem's own CHANGELOG for its fix and new
  `exe_spec.rb`.

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
  [`portage-cli`](https://github.com/tomtom87/Portage/blob/main/portage-cli/README.md).
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
