# Buy Skill, Local Store Index and the Shopper's Browser

**Status:** Phase 0 (skill + marketplace) and Phase 1 (`OfferSource` seam + Shopify Catalog) are committed. Phase 2a (categories + `Classifier` + find routing caps) is next. See [Progress log](#progress-log).
**Driver:** `portage find` only knows stores the user typed into `stores.yml` or that a search API returned for this one query. A fresh brew/gem install has nothing to go on, the big retailers are unreachable, and an agent has to learn the CLI from the README. This plan gives a fresh install a local store and product index the user builds themselves, lets the user's own browser feed it and finish purchases, routes the big retailers through hand-off only, and ships one `buy` skill that exposes all of it to agents.

## Context

**What exists.** `SearchBackends` ([search_backends.rb](../../portage-cli/lib/portage/cli/search_backends.rb)) is `Allowlist` (`~/.portage/stores.yml`/`PORTAGE_STORES`, query-independent, treated as trusted) → DuckDuckGo → Brave → Google CSE. Every backend returns URLs. `Find` probes at most 12 origins (`MAX_PROBES`) for `/.well-known/ucp`, then calls `search_catalog` on the ones that answer. `ProbeCache` remembers verdicts per machine.

**Big retailers don't serve public UCP.** A `GET /.well-known/ucp` on 2026-09-28 got 404 from walmart, target, etsy, wayfair, amazon and ebay, 403 (bot wall) from homedepot, and a timeout from bestbuy. allbirds (Shopify) returned 200 with a real manifest. The Google UCP launch partners are not reachable by a third-party agent today.

**Shopify's global catalog is open.** `catalog.shopify.com/api/ucp/mcp` answers `search_catalog` anonymously with a correct agent profile ([ucp-tool-gating-investigation.md](../ucp-tool-gating-investigation.md)). Results span merchants and carry each merchant's origin. It's referenced only in `Generate::AgentProfile` today, not used as a search source.

**WebMCP state (2026-09-28).** Phases 0-2 of [webmcp-universal-outbound.md](webmcp-universal-outbound.md) are committed. Phase 3 (approved autofill, `WebMcp::Autofill`, `Preset#checkout_selectors`) is in progress. It assumes the hand-off stays in the bridge's own browser, which is exactly what Phase 6 here provides. Phase 6 therefore supplies the browser, not the autofill.

**Amazon is hostile to agents.** Its Conditions of Use restrict robots and automated data extraction, and it sued Perplexity in November 2025 over an agent (Comet) shopping through users' own logged-in sessions. Being the user's own browser did not protect Perplexity.

## Decisions (2026-09-28)

1. **Known stores ship in the repo, not in the gem. The user can also build their own.** `portage-cli/known-stores/stores.json` and `products.json` are fetched at runtime over the same jsdelivr `@main` channel as the agent profile. That's free GitHub with no Actions. A new entry reaches every install on its next refresh, without waiting for a gem or brew release, so the lag is only as long as the maintainer takes to merge. Anyone updates the files by running `portage index build --export` and opening a PR. The user's own `portage index build` adds to the fetched list locally.
1a. **The user builds the index, not CI.** Portage is self-hosted and open source. `portage index build` runs on the user's machine from sources whose code they can read (one small file per source, listed by `portage index sources`). There's no central artifact, so no signing. The index still counts as untrusted data. It never feeds `merchant_allowlist` and never gets around the `--store` gate.
2. **Browser import is Tier A.** Bookmarks and history are opt-in, local-only, reduced to shop domains, and shown to the user before anything is saved.
3. **Hand-off goes to the user's own browser by default.** Their login, region, saved addresses and saved cards all apply because the user finishes the purchase. No affiliate tags and no region config.
4. **Driving a browser is Tier B, opt-in.** It uses a dedicated Portage browser profile, never the user's default profile. It can also hand off to an approved external agent (OpenClaw or similar), or to an approved agentic checkout route where the store grants one.
5. **Hand-off-only hosts are Tier C: on by default, and the user stays in control.** For Amazon (all marketplaces) and any host on the list, Portage opens the page and the user buys. The report says why, citing the site's terms. The list is config the user can edit. Removing a host only changes the message: Portage has no code that automates a site without UCP or WebMCP. Portage is open source and offered as-is, without warranty (MIT). A disclaimer says so in the README, `doctor`/setup, the skill, and every `handoff_only` report. How a user uses it on a given site is their choice and their responsibility.
6. **Setup is a wizard inside `doctor`.** `portage setup` (already a `doctor` alias) becomes interactive when run on a TTY. It walks through shipping, search API keys, agent profile, index build and browser import.
7. **One `buy` skill, distributed as a Claude Code plugin marketplace from this repo.** It's the agent-facing interface to everything above, and it detects features so it works against older CLIs.
8. **One phase per session**, logged below with a hand-off prompt (same rule as the WebMCP plan).

## Tiers

| Tier | What | Default | Guardrail |
|---|---|---|---|
| A | Import bookmarks/history as seeds; hand off to the default browser | on for hand-off; import opt-in | Domains only; user sees and approves the list; nothing leaves the machine |
| B | Portage-driven browser profile; address autofill; hand-off to an approved agent | off | Dedicated profile; domain allowlist; stops at payment; the user clicks pay; the browser's own card autofill, triggered by the user |
| C | Hand-off-only hosts (Amazon, etc.) | on by default, user-editable | Opens the page or search/cart-add URL only; no scraping or page reads; as-is disclaimer shown |

**Never, in any tier:** reading the browser's password, cookie or autofill stores; attaching to the user's default profile; solving or bypassing CAPTCHAs; putting card data through Portage.

## Phases

### Phase 0: `buy` skill and plugin marketplace ✅ (drafted)

- `.claude-plugin/marketplace.json` (repo root) lists one plugin, `buy`, at `plugins/buy`.
- `plugins/buy/skills/buy/SKILL.md` is the agent interface. It detects features from `portage --help`: `index`, `browser` and hand-off targets are used only when the installed CLI lists them. So the skill ships before Phases 1-7 and gains capability as they land.
- `plugins/buy/skills/buy/references/`: `outcomes.md` (every `--json` outcome and what to do), `raw-ucp.md` (the no-CLI fallback), `handoff-only.md` (Tier C and why).
- `skills/shop-via-ucp` stays for agents without the plugin system. Once Phase 8 lands it links to `buy` as the fuller interface.
- Before submitting to Anthropic's plugin directory: run `claude plugin validate .` and do one end-to-end dry run (`/buy` → `find` → `buy --dry-run`) in a clean Claude Code session.

### Phase 1: `OfferSource` seam + Shopify Catalog

- A second backend kind next to the URL backends: `OfferSource#offers(query, limit:, context:)` returns offers (the `Find#offer` shape plus `source`) directly, with no origin probe. `Find#call` merges them with the probed offers before `Decisions.rank`.
- `OfferSources::ShopifyCatalog`: `search_catalog` against `catalog.shopify.com/api/ucp/mcp`, using `PORTAGE_AGENT_PROFILE` and `BuyerContext`. Each offer's `store` is the merchant origin from the result. Buying from it then goes through the existing native-UCP path on that origin.
- **IDs (live check 2026-09-28, query "hiking boots", GB/GBP, 10 results):** `product.id` is a global catalog ID (`gid://shopify/p/…`) that the merchant won't recognise. But `variants[].id` is the merchant's own `gid://shopify/ProductVariant/…`, and `variants[].url` is on the merchant's domain (e.g. `https://www.lemsshoes.com/products/…`). The KISS route:
  - The offer's `store` is the origin of `variants[].url`, its `product_id` is that variant ID, and its `url` is the product page.
  - `Buy#select_product` also matches a product when one of its variants has `@product_id`, and `#line_item_id_of` then uses that variant. That's about 2 lines in `buy.rb`. No new flow and no title re-search.
- **Agent profile:** already solved. The repo publishes `portage-cli/agent-profile/agent-profile.json` over jsdelivr, and that URL works live against the catalog. The only gap is that the CLI reads it from `PORTAGE_AGENT_PROFILE` with no default, so a fresh install without `.env.example` copied fails. Fix: default to that URL when the variable is unset (one constant), and have `doctor` say which profile is in use.
- The call shape: arguments `{ catalog: { query:, context: }, meta: { "ucp-agent": { profile: } } }`. The existing `Transports::Http` already builds it.
- Category signal: the results carry `title` and `description.plain` but no category field. Phase 2a's `Classifier` supplies one.
- Counts toward nothing in `MAX_PROBES`. Needs a timeout, and failures are swallowed like `urls_from`.
- Files: `find.rb`, `search_backends.rb` (or a new `offer_sources.rb`). Also touches `buy.rb` for the variant match (about 2 lines) and one default constant.
- Specs: an offer merge and ranking spec, and a fake catalog endpoint. Live check: one real query, verify the merchant origins answer `/.well-known/ucp`.

### Phase 2a: categories and `Classifier` (fixes crowding now)

- `known-stores/categories.yml` (in `portage-cli/`): the top two levels of Google's published product taxonomy, about 200 nodes. Each node has keyword regexes. `~/.portage/categories.yml` overrides or extends it.
- `Classifier.categories_for(text)`: title, description or URL slug in (`/products/<slug>`, `/collections/<slug>`, `/c/<slug>`, `/category/<slug>`, `-` and `_` split into words), then ranked category IDs out. The same classifier serves queries, catalog products, stores and browser imports.
- `stores.yml` entries may carry `categories:`. The format stays a bare URL list; an entry becomes `{url:, categories: [...]}` only when tagged.
- `find` routing: classify the query, then take stores from the matching categories, **at most 3 per category and 12 in total**. Untagged stores are used only when the query names them, or when nothing else matches. Nothing falls back to "every store".
- Specs: classifier fixtures (queries, titles, slugs), and the routing caps.

### Phase 2b: local index + `portage index build`

- Commands:
  - `portage index build [--sources a,b] [--queries FILE] [--dry-run]`
  - `portage index refresh` (re-verify entries older than 7 days, add new ones)
  - `portage index show [--stores|--products] [--json]`
  - `portage index add URL` / `portage index remove HOST`
  - `portage index sources` (each source's name, what it fetches, file path)
- Storage: `~/.portage/index/stores.json` and `products.json`. Never in git. `doctor` reports whether each exists and its age.
- **Store entry:** origin, platform, UCP version, capabilities (catalog/cart/checkout), WebMCP preset if known, categories (top 5, weighted by how many of its products the `Classifier` put there), `sources` (which source found it), `last_verified`, `handoff_only`.
- **Product entry:** title, brand/vendor, GTIN/MPN when present, category, aliases, store origins with `last_seen`. **No prices or stock.** Those are always live.
- Sources (one file each under `portage-cli/lib/portage/cli/index/sources/`):
  - `shopify_catalog`: one query per taxonomy node (or `--queries FILE`). Harvests merchant origins (from `variants[].url`) and product identities.
  - `stores_file`: the user's `stores.yml`.
  - `browser`: Phase 3 output.
  - `wikidata` (optional, off by default, low yield): SPARQL for retailers' and brands' official sites. CC0. Keep it only if a trial run shows real hits.
  - `webmcp_sweep`: optional, needs a bridge. Detects the WebMCP preset per origin.
- Verification: one `/.well-known/ucp` probe per new origin through `ProbeCache`, throttled, with progress output. Capped at 500 per run by default.
- Routing: `SearchBackends::Index` applies Phase 2a's routing to index entries, and matches products by name or GTIN. The user's `stores.yml` ranks first, index entries next (`source: "index"`), web search last.
- The index never adds to `merchant_allowlist` and never counts as "picked a store" for `--yes`.

### Phase 2c: known-stores list in the repo

- `portage-cli/known-stores/{stores,products}.json`: the same schema as the local index, committed in the repo.
- Fetched from jsdelivr `@main` on first run, then on `portage index refresh`, or when `doctor` sees it's older than 7 days. Cached at `~/.portage/index/known-*.json`. Merged under the user's own entries, and the user's entries always win. Offline with no cache: find works as today.
- `portage index build --export DIR` writes a PR-ready copy with `sources` and `last_verified`, and nothing personal (history- and bookmark-derived entries are never exported).
- Generalise `rake agent_profile:purge` into a jsdelivr purge task that covers `known-stores/`.
- Seed the first committed list with one maintainer `portage index build --sources shopify_catalog --export`.

### Phase 3: browser import (Tier A)

- `portage browser import [--browser chrome|edge|brave|arc|firefox|safari] [--history-days 90] [--include-product-pages] [--dry-run]`
- Reads:
  - Chromium family: `History` (SQLite; copy first, it's locked while the browser runs) and `Bookmarks` (JSON)
  - Firefox: `places.sqlite`
  - Safari: `History.db` and `Bookmarks.plist`. Needs Full Disk Access on macOS; the command explains the prompt and never works around it.
- Reduces to domains. Checks them against the index and the hand-off-only list locally first. Then probes at most 200 unknown domains per run (`--max-probes`), skipping obvious non-shops (`NON_STORE_HOSTS`, webmail, banks, intranet and localhost hosts). Keeps only those that answer `/.well-known/ucp`, match a WebMCP preset, or are on the hand-off-only list. Shows the list and asks before writing. Stored as index entries with `sources: ["history"|"bookmark"]`.
- **Smarter import:** each kept history or bookmark entry runs through `Classifier` on its page title, bookmark folder name and URL slug (`/products/<slug>`, `/collections/<slug>`, `/c/<slug>`, `/category/<slug>`, `-` and `_` split into words). So a store gets categories from what the user actually looked at there, and visit count weights them.
  - Entries that match no category keep the domain uncategorised. They're routed only by name ("buy from allbirds"), never for generic queries.
  - The dry-run output shows each domain with its guessed categories, so the user can correct them before saving.
- `--include-product-pages` also keeps product page URLs and titles as product entries ("the one I looked at yesterday"). Off by default.
- Never reads cookies, `Login Data`, `Web Data` (autofill) or keychain entries. A spec asserts which files are opened.

### Phase 4: `portage setup` wizard

- On a TTY, `portage setup` (and `doctor` when it finds nothing configured) runs a wizard. Under `--json`, or with no TTY, it stays today's read-only report.
- Steps:
  1. Shipping address (`PORTAGE_SHIP_*`, written to `~/.portage/.env` with `chmod 600`).
  2. Search API keys (Brave, Google CSE). Explains that DuckDuckGo is keyless but only covers brand queries.
  3. Agent profile (`portage generate agent-profile`, and where to host it).
  4. Browser import (Phase 3).
  5. Index build (Phases 2b-2c).
  6. Spending policy caps (`policy set`).
  7. Hand-off target (Phase 5).
- Every step can be skipped, and it re-runs cleanly. Secrets never echo back.
- Touches `cli.rb` and `doctor.rb`.

### Phase 5: hand-off targets + hand-off-only hosts (Tiers A and C)

- `PORTAGE_HANDOFF_TARGET` / `--handoff-target`:
  - `default`: the system browser, via today's `CheckoutHandoff` auto-open
  - `profile`: the Portage profile (Phase 6)
  - `agent:<name>`: an approved external agent (e.g. OpenClaw), or a store's approved agentic checkout, invoked through a configured command or webhook. It receives the checkout URL and the approved cart summary (items, qty, total, store): the same payload as `--notify-webhook`. It gets no credentials, payment tokens or shipping details beyond what the checkout URL already holds. Each named agent is approved by the user once, in the wizard or config.
  - `print`: just report the URL
- `HandoffOnly` defaults: Amazon (every marketplace TLD) to start.
  - For these hosts `buy` returns outcome `handoff_only`, with a `checkout_url` (product page, or cart-add URL when the product ID is known) and a `legal_notice` explaining that the site restricts automated purchasing agents, so Portage opens the page and the user completes the purchase.
  - Without a product ID, which is the normal case until Phase 7, the link is the retailer's own search URL for the query. Portage builds that URL and doesn't fetch it.
  - The list is user config (`handoff_only_hosts:` in `~/.portage/config`), seeded with Amazon. The user can add or remove hosts. `doctor` shows the current list and the disclaimer.
  - `legal_notice` sticks to facts ("this retailer's terms restrict automated purchasing agents") plus the as-is line ("Portage is open-source software provided as-is, without warranty"). It doesn't give legal advice.
  - `find` may list them as candidates (from the index or browser history) but never fetches their pages.
- Touches `buy.rb`.

### Phase 6: Portage browser profile (Tier B)

- Chromium-family browsers first (Chrome, Edge, Brave, Arc). Firefox later over WebDriver BiDi. Safari is out (no equivalent automation for a signed-in profile).
- `portage browser profile init|open|status`: a dedicated Chromium profile directory under `~/.portage/browser/`, launched with remote debugging on that profile only. Chrome 136+ refuses remote debugging on the default profile, which is the right boundary. The user signs into their shopping sites there once.
- It becomes the WebMCP bridge for `buy` when `PORTAGE_HANDOFF_TARGET=profile`. The cart is built in the same browser the user pays in, which settles WebMCP Phase 1's "checkout URL across browsers" live check.
- Driving is limited to a domain allowlist (the store being bought from, plus its checkout host). Navigation anywhere else stops the run.
- Autofill: `WebMcp::Autofill` (WebMCP Phase 3, in progress) runs unchanged in this profile. This phase adds only the headed bridge and the domain allowlist. Payment is filled by the browser's own saved-card autofill, triggered by the user's gesture. Portage never touches card fields and never clicks pay.
- Build it on top of WebMCP Phase 3 once that's committed. Check that `autofill_needs_headed_browser` never fires when this profile is the bridge.

### Phase 7: retailer offer sources (hand-off only)

- Official buyer-side APIs as `OfferSource`s, keys set up through the wizard, each one opt-in:
  - Walmart Affiliate API
  - eBay Browse API (Buy It Now only)
  - Best Buy Products API
  - Etsy Open API v3 `findAllListingsActive` (buyer side; the existing `portage-ucp-etsy` is seller side)
  - Amazon Creators API / PA-API (verify which is current before building)
- Every one of these ends in hand-off (Tier C for Amazon). None of them completes a purchase. eBay's Order API guest checkout is out: it takes raw card data.
- Honour each API's caching terms. Nothing from these goes into `products.json` unless the terms allow it.
- One gem per retailer (`portage-ucp-walmart-buy`, …) or one `portage-ucp-retail` gem. Decide when Phase 1's seam exists.

### Phase 8: docs

- README, the CLI reference, `docs/cli-usage-tutorial.md` and `docs/skills/buy.md`.
- Update `skills/shop-via-ucp` to point to `buy`.
- Update the `buy` skill's references as each command lands.
- Design-log entry: the tiers, the hand-off-only rule and why.
- Skill release: bump `plugins/buy/.claude-plugin/plugin.json` `version` whenever the skill changes, and state the minimum `portage` version the skill's references assume. Before submitting to Anthropic's plugin directory, run a clean-session check: `/buy` for a brand query, a generic query, a hand-off-only query (Amazon), and a missing-setup case.

## Coordination with the WebMCP plan

| Phase | Touches | Parallel with the WebMCP plan? |
|---|---|---|
| 0 | new files only | done; commit it separately from the WebMCP work |
| 1-8 (incl. 2a-2c) | `find.rb`, `search_backends.rb`, `cli.rb`, `doctor.rb`, `buy.rb`, bridge | no. Decided 2026-09-28: start after WebMCP Phases 3-4 are committed |

## Out of scope

- Any DOM automation for search, variant choice or cart on sites without UCP or WebMCP. The WebMCP plan's out-of-scope line stands.
- Automating a hand-off-only host in any tier.
- A central, published index.
- Completing payment through Portage (see [agentic-payments.md](agentic-payments.md)).

## Open questions

1. Phase 2b: size of the starter query list for `shopify_catalog`, and whether to ship it per country.
2. Phase 5: the `agent:<name>` contract. A command template, a webhook, or both? Which external agents to name in docs?
3. Phase 7: one gem per retailer, or one `portage-ucp-retail`?
4. ~~Agent profile for a fresh install.~~ Resolved: it already exists (jsdelivr from the repo). Default to it in code (Phase 1).
5. ~~Do catalog IDs work for checkout?~~ Resolved live: use the variant ID and the variant URL's origin (Phase 1).
6. Phase 2a: taxonomy depth. Two levels (about 200 nodes) is the starting guess. Check the query count and harvest time on one build.

## Progress log

| Date | Phase | Result |
|---|---|---|
| 2026-09-28 | 0 | Drafted `.claude-plugin/marketplace.json`, `plugins/buy` (plugin manifest, `buy` skill, three references). Both manifests pass `claude plugin validate`. Not committed; the WebMCP agent is working on the same branch. |
| 2026-09-28 | review 2 | Known stores move into the repo, fetched over jsdelivr. Agent profile is already hosted; default it in code. Catalog live check: variant IDs are merchant-native, so about 2 lines in `buy.rb`. Shopify terms gate dropped. Category taxonomy and regex `Classifier` shared by find, index and import, capped at 3 stores per category and 12 total. Tier C list is user-editable, with an as-is/no-warranty disclaimer. |
| 2026-09-28 | review | Plan reviewed. Sequenced after the WebMCP plan. Phase 6 re-scoped to the browser only (autofill comes from WebMCP Phase 3). Added: fresh-install agent-profile blocker (OQ 4), catalog ID check (OQ 5), history probe cap, user-added hand-off-only hosts, `agent:` payload limits, stores.yml crowding fix, skill release checks. |
| 2026-09-28 | 0 | ✅ Committed. `.claude-plugin/marketplace.json` and `plugins/buy/` (plugin manifest, `buy` skill, three references) were already drafted and reviewed; this session confirmed `claude plugin validate .` still passes, added the root CHANGELOG entry, and committed the files on `buy-skill-local-index`. No subagent needed, per the Phase 0 note. A clean-session `/buy` dry run wasn't possible from this session (no interactive Claude Code session to install the plugin into); left for the pre-submission check the plan already calls for. |
| 2026-09-28 | 1 | ✅ Shipped `OfferSources` (`portage-cli/lib/portage/cli/offer_sources.rb`) and its first member, `OfferSources::ShopifyCatalog`, which calls `catalog.shopify.com/api/ucp/mcp` directly (5s timeout, failures swallowed like `SearchBackends`) and turns each result into an offer on the merchant's own origin, using the first variant's id/url rather than the catalog's own global product id. `Find#call` merges these with the probed offers before `Decisions.rank`; they count toward nothing in `MAX_PROBES`. `Buy#select_product` now also matches a product by a variant id, and `#line_item_id_of` checks that exact variant out (`variant_matching`, ~10 lines net in `buy.rb`). Added `Portage::Cli::AgentProfileUrl` (one constant, the jsdelivr URL `docs/agent-profile.md` already documents) so `PORTAGE_AGENT_PROFILE` defaults instead of failing a fresh install; `find.rb`/`buy.rb`'s `agent_meta` and `ShopifyCatalog` all resolve through it, and `doctor` reports which profile is in use. `portage-cli`: 509 → 526 examples (+17), 0 failures; `rubocop` clean (two `Metrics/CyclomaticComplexity` offenses from the merge fixed by extracting `nothing_to_go_on?` in `find.rb` and reusing `variant_matching` in `buy.rb`). Live check ran for real: `search_catalog("hiking boots", GB/GBP, limit 10)` against the real catalog endpoint returned 10 offers across 4 distinct merchant origins (lemsshoes.com, hillanddaleoutdoors.co.uk, keenfootwear.co.uk, kenetrek.com) in the same id/url shape the plan recorded on 2026-09-28, and all four answered `/.well-known/ucp` with 200 — no cart/checkout touched. No skill or outcome changed (`find`'s report shape is unchanged, just more offers in it; `outcomes.md` skimmed, nothing to update), so no `plugins/buy` version bump. |

### Session order

One phase per session, top to bottom. Each phase is sized to fit one session.

| # | Phase | Depends on |
|---|---|---|
| 0 | Skill + marketplace (commit the drafted files) | WebMCP plan done |
| 1 | `OfferSource` + Shopify Catalog, variant match, default agent profile | 0 |
| 2a | Categories + `Classifier` + find routing caps | 1 |
| 2b | Local index + `portage index` | 2a |
| 2c | Known-stores list in the repo, fetched over jsdelivr | 2b |
| 3 | Browser import, classified | 2b |
| 4 | `portage setup` wizard | 2c, 3 |
| 5 | Hand-off targets + hand-off-only hosts + disclaimer | 4 |
| 6 | Portage browser profile | 5, WebMCP Phase 3 |
| 7 | Retailer offer sources | 1, 5 |
| 8 | Docs + skill release | all |

### Reset prompt (same text every session)

> Continue `docs/plans/buy-skill-and-local-browser.md`. Branch: `buy-skill-local-index`. If it doesn't exist, create it from `main`, or from the tip of `webmcp-universal-outbound` if that hasn't merged.
>
> 1. Stop if the WebMCP plan (`docs/plans/webmcp-universal-outbound.md`) isn't finished (its progress log must show Phases 3 and 4 done and committed), or if `git status` shows uncommitted changes that aren't yours.
> 2. Read the plan's Context, Decisions, Tiers, Session order and Progress log. The next phase is the first row of the Session order table with no ✅ in the progress log. Read only that phase's section and the files it names.
> 3. Delegate the implementation to one Sonnet subagent (foreground). Give it the plan path, the phase, the branch and the rules below. Review its result, but don't redo its work.
> 4. Rules:
>    - Implement only that phase.
>    - Match the surrounding code style.
>    - No raw card data, and never read browser credential, cookie or autofill stores.
>    - Hand-off-only hosts are never automated.
>    - Any live check is read-only (no carts on real stores unless the phase says so).
>    - Don't push.
> 5. Finish:
>    - `bundle exec rspec && bundle exec rubocop` green in every gem touched; report the example counts.
>    - A CHANGELOG entry.
>    - The `buy` skill's references updated if the phase added a command or outcome. Bump `plugins/buy/.claude-plugin/plugin.json` `version` if the skill changed.
>    - A progress-log row ending in ✅.
>    - One commit on the branch.
>    - Then tell me the phase is done and which phase is next. I'll clear context and paste this prompt again.

**Phase 0 note:** that session only commits `.claude-plugin/`, `plugins/buy/` and this plan (no subagent needed), after a clean-session check of `/buy` if one is possible.

**Phase 1 note:** re-run the read-only catalog query first to confirm the variant-ID and variant-URL shape still holds.
