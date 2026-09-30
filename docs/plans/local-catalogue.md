# Local Catalogue: SQLite Index, Storefront Crawl, Product Cards, Packaging

**Status:** done (Phases 1-5 and the Phase 5 follow-ups: stable sort kept, title fallback tried and rejected). MIT-0 accepted (2026-09-30). Release cut and ClawHub publish are the user's, see "Next".
**Branch:** `local-catalogue` (off `main`)
**Driver:** a Grok thread proposing a full local product catalogue, card-shaped output for agents, and Omarchy/OpenClaw packaging. Other ideas from that thread (merchant promo config, localhost shopping UI, beacon registry) are **out of scope** here and come back as their own plans.

## Context (validated 2026-09-30)

Checked against the code and live endpoints before planning, not taken on trust:

- **The local index exists.** `portage index build|refresh|show|add|remove|sources` ([cli.rb:1361](../../portage-cli/lib/portage/cli.rb#L1361)) writes `~/.portage/index/{stores,products}.json` through `Index::Store` and `Index::ProductStore` ([product_store.rb](../../portage-cli/lib/portage/cli/index/product_store.rb)). Sources live in `index/sources/`: `shopify_catalog`, `stores_file`, `browser`, `wikidata`, `webmcp_sweep`.
- **The index never stores price or stock** (the `product_store.rb` header, Phase 2b of [buy-skill-and-local-browser.md](buy-skill-and-local-browser.md)). This rule stays.
- **Writes don't scale.** `ProductStore#upsert` rewrites the whole JSON file on every call. Crawling one 5,000-product store means 5,000 full-file rewrites. That is the reason for SQLite.
- **Public `/products.json` fields** (checked live on thelightyard.co.uk): the product has `id, title, handle, body_html, vendor, product_type, tags, variants, images, options`. Each variant has `id, title, option1-3, sku, available, price, compare_at_price, featured_image, …`. **There is no `barcode`, so no GTIN or UPC.** Paging with `?limit=250&page=N` works.
- **The card schema already exists in the spec.** `Portage::Ucp::Product` and `Variant` ([value_objects.rb:87](../../portage-ucp/lib/portage/ucp/value_objects.rb#L87), [:117](../../portage-ucp/lib/portage/ucp/value_objects.rb#L117)) carry `price_range`, `media`, `options`, `categories`, `variants`, `handle` and `url`, all with `to_wire_h`. But `Find#offer` ([find.rb:228](../../portage-cli/lib/portage/cli/find.rb#L228)) reduces every product to `title/amount/currency/url` and drops the rest.
- **Taxonomy mapping exists.** `Classifier` ([classifier.rb:11](../../portage-cli/lib/portage/cli/classifier.rb#L11)) maps text to Google product-taxonomy IDs.
- **SQLite gem:** `sqlite3` 2.9.x ships precompiled native gems for arm64/x86_64 darwin and x86_64/aarch64 linux-gnu/musl. That covers macOS, Omarchy (Arch, gnu) and Alpine.
  - **Caveat:** `script/homebrew-formula` pins the `ruby` platform gem only ([homebrew-formula:80](../../script/homebrew-formula#L80)), so Homebrew would compile the vendored SQLite from source. Phase 1 must validate this.
- **Existing SQLite use** is read-only, through the system `sqlite3` CLI ([browser_import/sqlite.rb](../../portage-cli/lib/portage/cli/browser_import/sqlite.rb)). That fits reading a locked browser DB, not an index we write thousands of rows to. Use the gem for the index and leave browser import alone.
- **OpenClaw skill format** ([docs.openclaw.ai/clawhub/skill-format](https://docs.openclaw.ai/clawhub/skill-format)):
  - Frontmatter needs `name`, `description` and `version`.
  - Requirements go under `metadata.openclaw.requires.{bins,env,anyBins,config}`. Optional env vars go in `metadata.openclaw.envVars` with `required: false`. `install` specs support brew.
  - ClawHub's scan **blocks publishing** if the metadata doesn't match what the skill references.
  - Published skills are licensed **MIT-0**.
  - Publish with `clawhub publish <dir> --slug <slug> --version <v>`.
- **mise:** `mise ls-remote gem:portage-cli` resolves (0.8.0–0.10.0), so `mise use -g gem:portage-cli` is an install path that needs no packaging work.

## Non-negotiable constraints

- **KISS.** One SQLite file, the stdlib-like `sqlite3` gem, plain SQL, no ORM. One new index source, no new "catalog" abstraction layer. No new CLI command group; extend `portage index`.
- **DRY.**
  - The product shape is the UCP `Product`/`Variant` wire shape. No parallel "card" or "catalog item" vocabulary.
  - The crawler maps `products.json` into `Portage::Ucp::Product` and persists from that one mapping.
  - Taxonomy goes through the existing `Classifier`.
  - HTTP goes through the existing `Support::Connection` and timeout conventions.
- **TDD.** Every phase writes failing specs first, in the existing `portage-cli/spec/portage/cli/index/**` layout. Use WebMock fixtures, no live HTTP in specs, and put the live checks under "validation". Suites and rubocop stay green (`rake spec`), with no new cop disables.
- **On spec.** Wire output follows UCP `to_wire_h` shapes. Portage-only fields sit outside UCP objects and are documented as such, the way `app.portage-ucp.reorder` is.
- **Keep the index public API.** `Index::Store` and `Index::ProductStore` keep their public methods (`all`, `find`, `upsert`, `exists?`, …). Callers such as `Builder`, `SearchBackends::Index`, `Doctor`, `BrowserImport` and `cli.rb` don't change in Phase 1.
- **Untrusted data.** Index rows are seeds. They never add to an allowlist, never skip the `--store` gate, never skip the user's pick or policy caps, and are never a source of price or stock.
- **Hand-off-only hosts are never crawled** (`HandoffOnly`, checked before any request, same as `Builder#probe_one_new_origin`).
- **File posture.** Index file is `0600`, and write failures raise.
- Out of scope: merchant promos, localhost UI, wishlist/cart, beacon/registry, and AUR packaging.

## Phases

One phase per session, delegated to a Sonnet subagent. Each phase ends with `rake spec` green, a progress-log row here, one or more commits on `local-catalogue`, and the restart prompt for the next phase. Don't push unless asked.

### Phase 1: SQLite index store

- Add `sqlite3` (`~> 2.9`) as a runtime dependency of `portage-cli`.
- New `Index::Database` owns `~/.portage/index/index.sqlite3`:
  - Opens with `0600`, WAL mode and a busy timeout.
  - A `schema_version` pragma (`user_version`) runs forward-only migrations.
  - `transaction { }` for batch writes.
- Tables, kept minimal:
  - `stores(origin PK, data JSON)`
  - `products(key PK, data JSON)`
  - `product_stores(key, origin, last_seen)`
  - `products_fts` (FTS5 over title, brand, category, aliases)
- JSON columns keep the existing entry shape verbatim, so Phase 1 is a storage swap, not a schema change.
- `Store` and `ProductStore` keep their public API and behaviour (alias and source merging included) and read and write through `Database`. Add `ProductStore#upsert_many` for batches, one transaction per batch.
- **Migration:** on first open, if `stores.json`/`products.json` exist and the DB is empty, import them in one transaction, then rename the files to `*.json.migrated`. Never delete them. Import exactly once, and don't import again after that.
- `KnownCache` (the downloaded known-stores list) and `Exporter` output stay JSON. They are published or fetched files, not the local store.
- `portage doctor` reports the index path, row counts and whether FTS5 is available.
- **Specs first:**
  - existing `store_spec` and `product_store_spec` pass unchanged against the SQLite backend
  - data survives a fresh process
  - JSON migration: happy path, runs once, originals are kept
  - `0600` on create
  - a failed write raises
  - `upsert_many` makes one transaction (assert it's atomic by failing halfway)
- **Validation (live, recorded in the log row):**
  - `PRAGMA compile_options` shows `ENABLE_FTS5` on macOS arm64 and linux-gnu (Docker `ruby:3.3`).
  - `gem install` of the built gem on a clean Ruby needs no compiler.
  - `script/homebrew-formula --out tmp/portage.rb` plus a local `brew install --build-from-source`. Decide between vendored and `depends_on "sqlite"` with `--enable-system-libraries`, and record why.
  - `portage index build` then `index show` on a real `~/.portage` copy matches the JSON-era output.

### Phase 2: Storefront catalogue crawl and `index search`

- New source `index/sources/storefront_products.rb` (name `storefront_products`) for Shopify's public `/products.json`. Its interface and registration match the other sources (`Index::Sources`).
  - Keep it Shopify-only for now, and give it a single `endpoint_for(origin, platform)` seam so WooCommerce's Store API can join later without restructuring (KISS: one platform now).
- **Map, don't reinvent:**
  - `products.json` product becomes `Portage::Ucp::Product`: `id`, `handle`, `url` = `origin/products/handle`, `media` from images, `options`, `tags`, `categories` from `Classifier` on `product_type` and tags, and `variants` with `id`, `sku` and `options`.
  - Price and availability are **dropped before persisting**.
  - Put the mapper next to the source, as a small module. If `portage-ucp-shopify`'s Mapper can be reused cleanly, reuse it; if not, say why in the log.
- **Persist:** the product entry gains `handle`, `url`, `image_url`, `options` and `variant_ids`, stored in the JSON column. The key stays GTIN/MPN when present (it never is here), otherwise the normalized title+brand, as today. Write one `upsert_many` per page.
- **When it runs:**
  - `portage index add URL`, and `portage index build --sources storefront_products` for origins already in the index.
  - Never implicitly during `find` or `buy`, so no request goes out the user didn't trigger. `check` only suggests the command as a next step.
  - Opt-in `--crawl` on `index add` if the default feels too heavy. Decide during the phase and log it.
- **Guardrails:**
  - Caps: max pages per store (default 20, so 5,000 products) and a per-run store cap.
  - Wait 1s between pages, honour `Retry-After` on 429 and stop that store on a second 429.
  - Respect `robots.txt` `Disallow` for `/products.json`.
  - A 404, an empty body, or HTML instead of JSON (a bot wall) means skip and note it on the store row.
  - Hand-off-only hosts are never requested.
  - Use the existing `UserAgent`.
- **`portage index search QUERY [--category ID] [--store HOST] [--limit N] [--json]`:** FTS5 match, filtered by category and store, returning index entries. Search order stays stores.yml, then index, then web, unchanged. `SearchBackends::Index` can use FTS for name routing if that's a simple swap; if not, leave it and log why.
- `index show --products` pages instead of printing everything.
- **Specs first:**
  - mapper fixture: a trimmed real `products.json` becomes the expected `Product` wire hash, with no price or availability persisted
  - pagination stops on a short page and at the cap
  - 429 back-off, then stop
  - robots disallow means no request
  - 404, HTML or empty means skip
  - a hand-off-only host makes zero requests (`WebMock::NetConnectNotAllowedError` posture)
  - `index search` ranking and filters
  - re-crawl upserts rather than duplicating
- **Validation:** crawl thelightyard.co.uk and one large Shopify store live, record timings and counts, and check `index search` returns sensible hits.

### Phase 3: Card-ready output for agents

- **One shape:** `find` offers and `index search` results carry a `product` field holding the UCP `Product` wire hash, as served. For `find` that means live from the store's catalog. For `index search` it's the persisted subset, without price.
  - Existing flat offer fields (`title`, `amount`, `currency`, `url`, `product_id`, `store`) stay, so nothing downstream breaks.
  - No new "card" object: the card *is* the UCP product plus the offer's live price.
- `Find#offer` passes the product through instead of reducing it. Cap `media` at the first image and `variants` at what the store returned. Offer sources (`OfferSources::ShopifyCatalog`, etc.) add the same `product` field where they already hold a UCP product; where they don't, they leave it out rather than faking it.
- **`index search` results are marked `live: false`.** The skill must re-fetch live (`find --store`, or `buy --dry-run`) before quoting a price or claiming stock.
- **Skill (`plugins/buy/skills/buy/SKILL.md` and references):** a short section on rendering offers as product cards (image, title, price range, store, key options, link). Use a host UI if one is available, otherwise a compact markdown list. Never show an index price as current. Keep it host-agnostic, with no host-specific UI code.
- Docs: document the `product` field in the CLI reference and `docs/agentic-flow.md`.
- **Specs first:**
  - the `find --json` offer includes the `product` wire hash equal to the stub catalog's product
  - flat fields are unchanged
  - `index search --json` has `live: false` and no price keys
  - an offer source without a product leaves the field out
- **Validation:** `claude plugin validate .` passes, and a headless `/buy` run renders cards from real `find --json` output (same method as the "clean-session /buy" row in [buy-skill-and-local-browser.md](buy-skill-and-local-browser.md)).

### Phase 4: Packaging for OpenClaw and Omarchy

- **One skill, no fork.** Add OpenClaw metadata to the existing `plugins/buy/skills/buy/SKILL.md` frontmatter:
  - `version`
  - `metadata.openclaw.requires.bins: [portage]`
  - `requires.config: [~/.portage/.env, ~/.portage/config.json]`
  - `envVars` for every env var the skill names (search keys, `PORTAGE_SHIP_*`, `PORTAGE_AGENT_PROFILE`, …), all `required: false`
  - `install` with the brew formula
  - `homepage`
- **Validate the merged frontmatter against both hosts:**
  - `claude plugin validate .` still passes.
  - A ClawHub dry run or inspect passes the metadata-mismatch scan. If the CLI has no dry run, publish to a throwaway slug from the **user's personal account**, per project memory.
- **Keep versions in step.** The skill's `version` follows the buy plugin's version (see the release commits). Add a spec or `rake` check that fails if they drift, reusing whatever already checks the plugin version.
- **Docs:** a short "OpenClaw" and "Omarchy" section in README's "Other agents" block and in the docs site:
  - OpenClaw: `clawhub install <slug>`, or a clone into OpenClaw's skills dir.
  - Omarchy: the CLI via `mise use -g gem:portage-cli`, or brew on Linux, then symlink the skill into `~/.agents/skills`. Verify Omarchy's actual skill paths before writing them down.
- **Not in scope:** AUR, an Omarchy bar widget, a second skill.
- **Licensing decision (the user's call, record it):** ClawHub republishes the skill as MIT-0. The repo is MIT. Confirm that's acceptable before the first publish.
- **Specs and checks first:** the frontmatter version-sync check, and a YAML-parse check of the frontmatter.
- **Validation:** a fresh `mise use -g gem:portage-cli` in a clean Arch container (`archlinux:latest`) gives a working `portage --version` and `portage doctor --json`. OpenClaw loads the skill and gates it when `portage` is missing.

### Phase 5: Taxonomy pass and Omarchy doc fix

**Why:** Phase 2 found the keywords too coarse for real catalogues:
- "Pendant Light" classifies to nothing.
- The tag "New Collection" hits `4488` Electronics > Toll Collection Devices.
- "Kitchen" tags pull a lighting store into Kitchen & Dining.
- `--category 594` (Lighting) returned 1 of 164 Light Yard products.

**Causes** (checked in [classifier.rb](../../portage-cli/lib/portage/cli/classifier.rb) and `known-stores/categories.yml`):
- **Keywords come from node and parent names only** (two levels, 213 nodes). Google's deeper nodes, which carry the specific words ("Chandeliers", "Ceiling Light Fixtures", …), are never used.
- **Every keyword scores 1.** A generic parent word ("electronics", "home", "kitchen") or a merchandising word ("collection", "new", "sale") counts as much as a specific one.
- **No generator in the repo.** The file header points at "the script that built" it, but that script isn't in `script/`, so the data can't be regenerated or reviewed.

**Callers** (all go through `Classifier.categories_for`, so nothing else changes):
- `SearchBackends` (`find` routing, [search_backends.rb:138](../../portage-cli/lib/portage/cli/search_backends.rb#L138), [:282](../../portage-cli/lib/portage/cli/search_backends.rb#L282))
- `Index::Builder`
- the `StorefrontProducts` source and mapper
- `BrowserImport::Categorize`

**Step 0, Omarchy doc fix.** Validated 2026-09-30, see "Omarchy validation" below. Rewrite README's Omarchy bullet:
- Install with Omarchy's own helper: `omarchy-mise-install gem:portage-cli portage`, which writes the `~/.local/bin/portage` wrapper the same way Omarchy installs `claude`, `codex` and `gh`. Keep `mise use -g gem:portage-cli` as the plain-mise alternative.
- State that a stock Omarchy needs `sudo pacman -S --needed make` first. Replace the "`base-devel`" line: `gcc` is already there through `clang`, and only `make` is missing.
- Skill paths: `~/.agents/skills` (OpenClaw, and the dotagents route), `~/.claude/skills` (Claude Code; the plugin route is preferred), and `~/.codex/skills`. These are the same directories Omarchy's own `omarchy-provision-user` links into. Drop "could not verify".

**Taxonomy pass (KISS: data and scoring only; no new classifier, no LLM, no network at runtime):**
1. **A committed, reproducible generator.** Add `script/categories`, stdlib-only like `script/homebrew-formula`.
   - Reads Google's taxonomy file: fetch it, or pass `--from FILE`. Pin the edition in the header.
   - Emits `known-stores/categories.yml` with the **same ids and shape**, still the top two levels as keys, so `~/.portage/categories.yml` overrides keep working.
   - Level-2 nodes gain `keywords` from **their own descendants' names** (levels 3+), rolled up.
   - Parent words are kept, but in a separate `parent_keywords` list.
2. **A shipped stoplist** of merchandising and non-product words: new, collection, sale, gift, set, accessories, supplies, other, general, …. It's a short YAML list the generator applies and the Classifier also applies to input tokens. Every word on it gets a spec-backed reason.
3. **A small curated synonyms layer** under a `synonyms` key per node, applied by the generator. It's only for real gaps the golden set proves (e.g. pendant, sconce, chandelier → Lighting). Each synonym is justified by a golden case. No bulk hand-curation.
4. **Scoring.** Own and descendant keywords count 2, `parent_keywords` count 1, ties unchanged. This is the only change to `Classifier`. `categories_for`'s signature and return shape stay the same. Only reach for IDF-style weighting if the golden set shows 2/1 isn't enough, and log why.
5. **Golden set:** `portage-cli/spec/fixtures/classifier_golden.yml`, 60–100 labelled cases.
   - Taken from real data: Light Yard products (from the Phase 2 crawl), JB Hi-Fi products, existing `find` spec queries, and a few browser-import-style URLs.
   - Each case has an expected top-1 category id, plus an optional "must not include" list.
   - It's written **before** any data or scoring change, and the baseline accuracy is recorded.

**Constraints:**
- `find` routing must not regress. Every existing `search_backends`, `find` and `index` spec passes unchanged. Where an old spec asserted a wrong category, fix the expectation and name it in the log.
- `categories.yml` stays shipped in the gem. Only grow its size if it stays reasonable (log before and after).
- `index search --category` must work on data that's already indexed without a re-crawl. Either re-classify existing rows on `index refresh`, or document "re-crawl to re-classify". Pick the simpler one and log it.

**Specs first:**
- **Golden-set spec:** the top-1 accuracy threshold is set from the baseline and raised to the target. It asserts the specific Phase 2 failures: "Pendant Light" → Lighting, "New Collection" never → 4488, a lighting product tagged "Kitchen" ranks Lighting first.
- **Generator specs** on a tiny taxonomy fixture: ids and shape preserved, descendants rolled up, stoplist applied, synonyms merged, output deterministic.
- **Classifier specs:** 2/1 weighting, stoplisted input tokens ignored, user overrides still win.

**Validation:**
- Regenerate `categories.yml` and diff-review it (spot-check 10 nodes).
- Re-classify or re-crawl thelightyard.co.uk. `portage index search --category 594` should return most of the lighting products; record the before/after counts.
- `portage find` on 5 real queries routes as before or better. Record each query.
- Golden-set accuracy before and after, in the log row.

## Open decisions

1. Vendored SQLite vs `depends_on "sqlite"` in Homebrew. **Decided in Phase 1: vendored** (see "Phase 1 results").
2. `index add` crawls by default or only with `--crawl`. **Decided in Phase 2: only with `--crawl`** (see "Phase 2 results").
3. MIT-0 on ClawHub. **Decided 2026-09-30: accepted.** The repo stays MIT; ClawHub republishes the skill as MIT-0.
4. Release cut (versions, CHANGELOG, `rake publish_all`, `rake homebrew:update`) after Phase 5, as its own step, only when asked.

## Progress log

| Date | Phase | Result |
|---|---|---|
| 2026-09-30 | plan | Drafted and validated against the code, live `products.json`, the `sqlite3` gem platforms, ClawHub skill-format docs and `mise ls-remote gem:portage-cli`. |
| 2026-09-30 | 1 | **Done** (commits `Store the local index in SQLite`, `Report the index database in portage doctor`; unpushed). `rake`-equivalent for portage-cli: rspec 1103 -> 1131 examples, 0 failures; rubocop clean, no new disables. Existing `store_spec`/`product_store_spec` pass unchanged. See "Phase 1 results" below the table. |
| 2026-09-30 | 2 | **Done** (commits `Classify long texts without comparing every word to every keyword`, `Crawl a Shopify store's products.json into the local index`, `Add portage index search and page index show --products`, `Document the catalogue crawl and index search`; unpushed). portage-cli rspec 1131 -> 1201 examples, 0 failures; rubocop clean, no new disables; each commit green on its own. `index add` crawls only with `--crawl`. Live: thelightyard.co.uk 164 products in 3.5s, JB Hi-Fi 5,000 (page cap) in 36s, re-crawls upsert with no duplicates. See "Phase 2 results".
| 2026-09-30 | 3 | **Done** (commits `Carry the UCP product on find offers and index search hits`, `Document product cards in the buy skill and CLI reference`; unpushed). portage-cli rspec 1201 -> 1211 examples, 0 failures; rubocop clean, no new disables. `find` and `shopify_catalog` offers carry `product`; `index search` is `live: false` with a price-free `product` per hit. `claude plugin validate .` passes. Headless `/buy` run **skipped** (claude -p: "OAuth session expired"), replaced by a manual render check on real `find --json`. See "Phase 3 results".
| 2026-09-30 | 4 | **Done** (commits `Add OpenClaw metadata to the buy skill and check it against the plugin`, `Document installing the buy skill on OpenClaw and Omarchy`; unpushed). portage-cli rspec 1211 -> 1218 examples, 0 failures; rubocop clean. `claude plugin validate .` passes. Arch container: `mise use -g gem:portage-cli` gives a working `portage --version`/`doctor --json` (needs a compiler). **Skipped:** ClawHub dry run/scan (blocked, nothing published), OpenClaw runtime gating, Omarchy skill path (unverifiable). See "Phase 4 results".
| 2026-09-30 | Omarchy | **Validated** against Omarchy `8b4eae6` (2026-09-29) and an Omarchy-like Arch container. `omarchy-mise-install gem:portage-cli portage` fails on the stock base packages (`make` is missing) and works once `make` is added. Skill paths confirmed from Omarchy's source. README fix and taxonomy pass added as Phase 5. See "Omarchy validation". |
| 2026-09-30 | 5 | **Done** (commits `Fix the Omarchy install steps in the README`, `Add a golden set for the category classifier`, `Rank category matches by repetition and rarity and keep only the strongest`, `Generate the category keywords from Google's taxonomy with a stoplist`, `Add the category synonyms the golden set proves are missing`, `Replace a duplicate golden case`, plus the docs commit; unpushed). portage-cli rspec 1218 -> 1271 examples, 0 failures, 0 pending; rubocop clean (227 files), no new disables; each commit green on its own. Golden top-1 accuracy 12/100 -> 70/100. Light Yard `--category 594`: 1 of 164 -> 160 of 164 after a re-crawl. `categories.yml` 20,778 -> 101,155 bytes. No existing spec expectation changed. See "Phase 5 results". |
| 2026-09-30 | 5 follow-ups | **Done** (commits `Keep first-seen order for equally weighted browser-import categories`, plus the docs commit; unpushed). portage-cli rspec 1271 -> 1272 examples, 0 failures; rubocop clean, no new disables. The stable sort is kept. **The `Mapper` title change was tried in two forms (title + type + tags; title only as a fallback) and rejected:** the first regressed Light Yard and the JB sample, the second passed those bars but lowered precision and changed JB's store-row routing. No mapper code committed. Golden stays 70/100, threshold stays 0.70. No existing spec expectation changed. See "Phase 5 follow-up results". |

### Phase 1 results (2026-09-30)

**Built:** `Index::Database` (open/0600/WAL/busy timeout, reentrant `transaction`, `entries/get/put/delete/count/execute/info`), `Index::Schema` (forward-only `MIGRATIONS`, `fts5_available?`), `Index::LegacyImport`. `Store`/`ProductStore` keep their public APIs and now sit on it; `ProductStore#upsert_many` added. `portage doctor` index finding gains the DB path, row counts and FTS5 status (`details.database`). CHANGELOG `[Unreleased]` entry added. `sqlite3 ~> 2.9` added to the gemspec (resolved 2.9.6).

**Validation:**

1. **FTS5: pass.** `PRAGMA compile_options` has `ENABLE_FTS5` (SQLite 3.53.2) on macOS arm64 (gem 2.9.6 arm64-darwin), Docker `ruby:3.3` linux aarch64 (`aarch64-linux-gnu`), and `ruby:3.3-slim` under `--platform linux/amd64` (`x86_64-linux`, emulated). Not tested: musl/Alpine (gem ships precompiled, but I did not run it).
2. **`gem install` with no compiler: pass.** Built `portage-cli-0.10.0.gem` from the working tree, installed it in `ruby:3.3-slim` (no gcc/cc/make; checked with `which`) on arm64 and amd64. Both pulled the precompiled `sqlite3-2.9.6-<platform>-gnu`, `portage --version` gave 0.10.0, `portage doctor` printed the new index-database line with FTS5 available.
3. **Homebrew: pass, vendored SQLite chosen.** `script/homebrew-formula --out tmp/portage.rb` needs no change: it already resolves `sqlite3` 2.9.6 and `mini_portile2` from the gemspec as ordinary `resource` blocks (ruby-platform sha256 matched). A real `brew install --build-from-source` of a renamed, keg-only copy (class `PortageValidate` in a throwaway tap `local/portage-validate`, `url` pointed at the locally built gem, so the keg ran the new code; the real `tomtom87/portage` install was untouched, and the copy was uninstalled and untapped afterwards) took about 56s in total and built sqlite3 from the gem's bundled amalgamation with no network fetch. The keg's Ruby reported SQLite 3.53.2 with `ENABLE_FTS5`, and `portage doctor --json` showed the database block with `fts5: true`. **Why vendored, not `depends_on "sqlite"` + `--enable-system-libraries`:** (a) `sqlite` is keg-only on macOS, so system-libraries needs extra pkg-config/`--with-sqlite3-*` wiring; (b) the formula installs every resource in one loop, so one resource would need special-casing in `script/templates/portage.rb.erb`; (c) FTS5 and JSON1 then depend on whichever SQLite the machine has, whereas vendored gives the same 3.53.2 build as the precompiled `gem install` path; (d) the only cost is a C compiler at build time, which a source build needs anyway. Revisit only if a Homebrew reviewer objects to bundled SQLite.
4. **`index build` then `index show` on a real `~/.portage` copy: pass, with a live-data caveat.** All runs used `HOME` pointed at copies under `tmp/validate/` (real `~/.portage` untouched, no sqlite file appeared in it). The real dir has no `stores.json`/`products.json` (only the known-* caches), so:
   - Old code (worktree at the plan commit) built a JSON-era index on a copy (163 stores). New code's `index show --json` on that same copy migrated it: output **byte-identical**, files renamed to `*.json.migrated`, DB mode 0600.
   - Same again with `products.json` seeded from the real known-products.json (396 products): `index show --json` and plain `index show` both **byte-identical** old vs new.
   - Two full `index build` runs from identical copies, old JSON code vs new SQLite code (both live): 235 vs 234 stores, 230 in common, 406 vs 407 products, and the only differences in shared stores were `categories` weights (6 stores, live catalog sampling). Entry key sets are identical. The first old-code run (163 stores) was an outlier, most likely from network flakiness, so I re-ran it rather than trust it. New build took about 4 min. No regression seen, but exact equality is only claimable for the migration path.

**Judgement calls:**
- The DB sits **beside the path the store is given** (`Database.path_for(json_path)` = `dirname/index.sqlite3`), so `Store.new(path: ".../stores.json")` and the spec-helper redirects work unchanged and both stores share one file. The `stores.json` path is now only the location of the legacy file to import.
- **Import happens only on the open that creates the database** (not "whenever a table is empty"), inside the same transaction as the schema migration, so it is exactly once and a failed import leaves the DB unstamped and is retried. A spec proves "exactly once" after the tables are emptied again. Non-object entries and unparseable files are skipped (file left untouched).
- `products` has `id INTEGER PRIMARY KEY` plus `key TEXT UNIQUE`, not `key` as the primary key as the plan sketched, so `products_fts` can share a rowid that survives VACUUM. `product_stores` and `products_fts` are maintained by SQL triggers (JSON1 `json_extract`/`json_each`), so the legacy import and future bulk writes need no extra Ruby indexing code.
- The FTS migration is a no-op (version still advances) on a SQLite without FTS5; `doctor` reports it. Phase 2's `index search` must handle that.
- `Store#exists?` now means "the database file exists, or a legacy json is waiting to be imported", so `doctor` doesn't say "no index" before the first migration. Reads never create the file.
- Store#upsert/remove and ProductStore#upsert run in `BEGIN IMMEDIATE`, so read-modify-write is safe across processes. Failed writes raise (`Errno::EACCES` for an unwritable dir, `SQLite3::Exception` otherwise); the Builder's `rescue StandardError` blocks only wrap source fetches, not store writes, so a write failure now surfaces from `index build`/`add`.
- The `Index::Database.new` default is redirected to a tmpdir in `spec_helper.rb`, like the other index paths.
- Not done, deliberately: no price/stock stripping in `ProductStore` (behaviour unchanged; Phase 2's mapper drops them), `Builder` still calls `upsert` per sighting, `KnownCache`/`Exporter` untouched.

**Bugs caught while building (by the specs):** `fts5_available?` returned the DB object, not a boolean (block form of `SQLite3::Database.new`); an "import if table empty" rule re-imported after `index remove` emptied a table, which the "imports exactly once" spec caught and led to the import-on-create rule; an empty `upsert_many` created the DB file.

### Phase 2 results (2026-09-30)

**Built:**
- `Index::Sources::StorefrontProducts` (`index/sources/storefront_products.rb`, registered as `storefront_products`, not in `DEFAULT_NAMES`). It has three small helpers beside it:
  - `Mapper`: products.json product -> `Portage::Ucp::Product`, then the index sighting taken from that Product.
  - `Pages`: HTTP, paging, 429 handling, and the page-body checks.
  - `Robots`: just enough RFC 9309 to answer "may this agent GET this path".
- `endpoint_for(origin, platform)` is the one platform seam (Shopify or unknown platform -> `/products.json`, else nil).
- `Builder` changes:
  - Takes `store_fields:` (crawl note, platform) from a sighting onto the store row.
  - Takes `product:` (handle, url, image_url, options, variant_ids) onto the product entry.
  - Uses a source's own `categories:` when it gives them.
  - Writes product sightings through `upsert_many`, 250 per transaction.
  - `add(url, crawl:)` backs `index add URL --crawl`.
- `Index::Search` holds the SQL. `ProductStore` gains `#search`, `#search_engine`, `#page` and `#count`.
- CLI: `index search`, and `index show --products --page N --per-page N` (default 50, reports `products_total`).
- `check` adds `index_hint` (the `index add ORIGIN --crawl` command) for a Shopify or native-UCP store and never crawls.
- Docs: usage banners, `docs/api/cli-json.md`, the tutorial, the portage-cli README source table. portage-cli CHANGELOG `[Unreleased]` entry.
- No schema migration was needed: the new entry fields live in the JSON `data` column, and FTS stays over title, brand, category and aliases.

**Validation** (all with `HOME` pointed at temp dirs under `tmp/validate/p2v/`, seeded only with copies of the `known-*.json` caches; the real `~/.portage` was untouched, and no sqlite file appeared in it):
1. **thelightyard.co.uk: pass.**
   - `index add https://thelightyard.co.uk --crawl --json`: verified UCP, `crawl: {status: ok, pages: 1, products: 164}`, 3.5s wall in total (probe + robots + one page). That gave 164 product rows, DB mode 0600.
   - A second crawl via `index build --sources storefront_products` took 1.8s and left 164 rows (upsert, no duplicates).
   - `data LIKE '%"price%' OR '%"available%'` matched 0 rows.
2. **Large Shopify store (JB Hi-Fi, www.jbhifi.com.au): pass.**
   - `index add ... --crawl` took 36.2s wall (19s of it is the 1s pauses) for 20 pages / 5,000 products, stopping at `partial`/`page_cap` as designed. That gave 4,961 rows: 39 sightings shared a brand+title key with another product and merged, as the existing key rule does. DB about 8.4MB.
   - Re-crawl: 34.4s, still 4,961 rows. No price or availability in any row.
3. **Other live outcomes, recorded as seen:**
   - allbirds.com: 692 products / 3 pages, 7.9s.
   - gymshark.com: `skipped`/`http_403` on robots.txt or products.json (bot wall), no products written.
   - fashionnova.com: `skipped`/`not_found` (its `/products.json` answers 404; confirmed with curl).
4. **`index search` sanity: pass, with a category caveat.**
   - Queries tried: lightyard "bathroom pendant", "wall lights", "birdcage", "gold leaf" and "outdoor bollard"; JB "airpods", "iphone 17 case", "samsung tv" and "headphones". All returned the obvious products first, about 0.43s wall per call, which is mostly Ruby start-up.
   - `--store thelightyard.co.uk` kept hits, and `--store other.example` gave none (exit 1). `--json` has `engine: "fts5"` and no price or availability keys.
   - "brass" finds nothing on lightyard, because that word appears only in tags and descriptions, which are not in FTS (as planned).
   - **Categories are weak for this store.** The shipped taxonomy keywords are coarse: "Pendant Light" classifies to nothing, the tag "New Collection" hits "Toll Collection Devices", and "Kitchen" tags hit "Kitchen & Dining". As a result, `--category 594` (Lighting) returned 1 lightyard product. This is a Classifier data limit (the keywords come from `known-stores/categories.yml`), not a crawl bug. It is left for a taxonomy pass, because changing keywords also changes `find` routing.
5. **`find`'s index backend on a 5k-product index:** `SearchBackends::Index#search` took 163ms / 112ms on the JB DB, versus 25ms / 14ms on lightyard. That is acceptable, so it is not swapped to FTS (see below).

**Judgement calls:**
- **`--crawl` is opt-in.** A plain `index add` stays one probe. A crawl is up to 22 requests (robots.txt + 20 pages + one 429 retry) and about 20s of pauses, which is too heavy to be a side effect of adding a store. `check` prints the command instead.
- **The mapper is ours, not portage-ucp-shopify's.** That Mapper reads Storefront GraphQL nodes (camelCase, gids, MoneyV2 with currency), not the REST products.json shape, and portage-cli doesn't depend on that gem.
  - `Mapper.product` builds the full UCP Product, including the store's price (no currency, because products.json has none) and availability.
  - `Mapper.sighting` takes only identity fields from it. That is where price and availability are dropped.
  - Shopify's placeholder `Title: Default Title` option is removed.
  - Categories: the top three Google ids from Classifier on `product_type` + tags, plus the store's `product_type` as a `merchant` category on the Product. The index keeps the first Google id as `category`, as before.
- **Robots:**
  - A 4xx robots.txt means no rules. A 5xx, a redirect or no answer means stay out (RFC 9309).
  - Rules are checked against every page URL.
  - Page 1 is requested as the bare `?limit=250`, so a rule aimed at duplicate `?page=1` URLs doesn't read as a ban on the whole catalogue.
- **The stored `handoff_only: true` doesn't block a crawl. Only the live HandoffOnly list does**, the same rule as Builder's re-verify. `index add` stores that flag for any store without `/.well-known/ucp`, which is not the same as Tier C.
- **`SearchBackends::Index` is not swapped to FTS.** Its match is two-way: the query's words in a title, or a whole title named inside a longer query. It also covers GTIN, and it runs over the known-products JSON cache, which isn't in SQLite. A prefix MATCH would change routing semantics, and at 5k rows the current scan is still about 160ms.
- **Search words:** only letters and digits reach MATCH (no FTS syntax injection). Each word is a prefix after dropping a trailing `s`/`es`/`ies` (only for words longer than 3 letters). All words are required, ranked by bm25 with weights title 10, aliases 5, brand 3, category 1. The LIKE fallback applies the same filters, unranked.
- **Classifier speed-up** (its own commit): each keyword's accepted forms are looked up in a hash of input words. A script checked every taxonomy keyword against its plural and singular variants and random words: 0 mismatches against `word_match?`.
- Store cap: 25 a run, least recently crawled first (`crawl.at`), so repeated `index build --sources storefront_products` runs rotate through the index.

**How this phase ran, and bugs caught:** the session started with most of the Phase 2 code and specs already in the working tree, uncommitted, from an earlier interrupted run, along with its scratch validation output under `tmp/validate/p2/`. That work was reviewed line by line against the plan and re-validated from scratch (the numbers above are from this session's own runs), not trusted as-is.
- **Found in review:** robots.txt was fetched with `Accept: application/json` (shared GET helper). It is now `text/plain`, with a failing spec first.
- **Found in review:** the Classifier refactor was checked for exact equivalence (script above) before it was committed, since `find` routing depends on it.
- **Visible in the earlier run's leftovers, not seen first-hand:** that run's fashionnova.com crawl was `skipped`/`robots`, while this session's was `not_found`. The spec "requests page 1 without page=" pins the fix that most likely explains the difference: a bare page-1 URL, so a duplicate-URL rule doesn't block the catalogue.

**Not done, deliberately:**
- Tags and description are not in FTS (a new migration can add them if Phase 3 wants it).
- No WooCommerce endpoint yet (the seam is there).
- Brand+title key collisions within one store merge. The later sighting's url, handle and variant_ids win, as for any other field.

### Phase 3 results (2026-09-30)

**Built:**
- `OfferSources.with_product(offer, product)`: adds the UCP Product wire hash as `product` (media cut to the first image) and leaves the offer untouched if there is no non-empty hash. `Find#offer` and `ShopifyCatalog#offer` use it; the retailer APIs (Walmart, eBay, Best Buy, Etsy, Amazon) hold no UCP product and are unchanged.
- `Index::EntryProduct.wire(entry)`: an index entry as the persisted subset of a UCP Product wire hash (`title`, `handle`, `url`, `media` [first image], `options`, `variants` [ids only], `categories`), built through `Ucp::Media`/`Ucp::Category`. Fields the entry lacks are left out.
- `index search` result gains `live: false` and `product` on every hit (entry fields kept beside it). Text output ends with a "not live" line.
- Skill section "Showing offers as product cards" plus the index-hit rule (never show an index price as current); `docs/api/cli-json.md`, `docs/agentic-flow.md`, portage-cli and root CHANGELOG `[Unreleased]` entries.

**Validation** (scratch `HOME` at `tmp/validate/p3v/home` via a `portage` wrapper on PATH; the real `~/.portage` was untouched, no sqlite file in it):
1. **`claude plugin validate .`: pass.**
2. **Live `find --query "bathroom pendant light" --json`: pass.** 5 `shopify_catalog` offers, all with `product` (1 image, 1 variant, `price_range`, options), 2-3.5KB each; flat fields as before.
3. **Live `index search` after `index add https://thelightyard.co.uk --crawl` (164 products): pass.** `live: false`, `engine: fts5`, `product` with first image and variant ids; no `price`/`amount`/`currency`/`available` key anywhere in the JSON.
4. **Headless `/buy` rendering cards: SKIPPED.** `claude -p` (with and without `--setting-sources local`) fails with "Failed to authenticate: OAuth session expired and could not be refreshed" in this environment. Substitute: rendered cards (image, title, price and range, store, options) by script from the real `find --json`, which checks the fields exist but not that a model follows the skill. Re-run when a session is authenticated (`claude -p --setting-sources local --plugin-dir plugins/buy`, `portage` wrapper on PATH with a scratch HOME, `portage buy` disallowed).

**Judgement calls:**
- **Offers only get `product` if it exists**, no empty key and no faked one. In `find`, offers from a probed store or from `shopify_catalog` have it; retailer-API offers do not.
- **Media cut only on the product's own `media`** (variants keep theirs, as the store returned them). `price_range` in the passthrough is the store's live price; the flat `amount` stays the ranking value.
- **Index `product` has no `id`.** The entry stores variant ids but not the product gid, so none is invented. It is a subset of UCP Product (not schema-complete: `description`, `price_range` and `id` are required by the spec).
- **`live: false` is always false** (a constant, not computed), as the plan asks; a future live-verified search would flip it.
- **`history` does not save `product`.** `History#saved_offers` already whitelists fields; a spec pins it so the history file does not grow by 2-3KB an offer.
- `compare` inherits `Find#offer`, so its offers carry `product` too, with no extra change.
- `SearchBackends::Index` and the index `category` are unchanged (see Phase 2).

**Bugs caught by specs:** the existing "uses the merchant's variant url/id" spec (`eq` on the whole offer) failed when `product` was added; it now includes the product. A first version used `.compact` on the offer, which would have dropped `amount: nil`; the spec showed the flat shape had to be kept, so `with_product` merges instead.

**Not done, deliberately:** no price range or currency in index cards (the index has no price); no image beyond the first; no new card object.

### Phase 4 results (2026-09-30)

**Built:**
- `plugins/buy/skills/buy/SKILL.md` frontmatter gains `version: 0.8.0` (= `plugins/buy/.claude-plugin/plugin.json`) and `metadata.openclaw`: `homepage`, `requires.bins: [portage]`, `requires.config: [~/.portage/.env, ~/.portage/config.json]`, a brew `install` spec (`tomtom87/portage/portage`, bins `portage`) and 18 `envVars`, all `required: false`, each with a description. No `requires.env`, `primaryEnv` or licence field. Same file, no fork.
- `portage-cli/spec/packaging/buy_skill_frontmatter_spec.rb` (7 examples): frontmatter parses as YAML with name/description/semver version; skill version equals `plugin.json`; bins/config/install/homepage are as declared; nothing is `required`; every `PORTAGE_*`/`BRAVE_*`/`GOOGLE_*`/`ETSY_*` name in the skill and its references is declared (and the `_CITY`... suffix forms the skill lists next to `PORTAGE_SHIP_STREET`); nothing declared that the skill never mentions. Written first and seen failing, then made green. Mutation check: bumping `plugin.json` alone fails it.
- README "Other agents" gains OpenClaw and Omarchy bullets (the docs site includes that block, so `docs/skills/buy.md` needs no edit). Root CHANGELOG `[Unreleased]` entry. portage-cli has no code change, so no CHANGELOG entry there.

**Validation:**
1. **`claude plugin validate .`: pass** (marketplace) and `claude plugin validate plugins/buy` (plugin manifest): pass. Neither reads SKILL.md frontmatter beyond what Claude Code already accepts.
2. **OpenClaw skill-format docs re-fetched** (docs.openclaw.ai/clawhub/skill-format, /clawhub/publishing, /tools/skills). The metadata shape used matches the "complete frontmatter" example. `envVars` with `required: false` is the documented home for optional vars.
3. **Arch container (`archlinux:latest`, linux/amd64 under emulation on an arm64 Mac): pass, with two findings.**
   - `mise use -g gem:portage-cli` resolved the **released 0.10.0** gem (rubygems already has it, and it includes the SQLite index), and `portage --version` gave 0.10.0. `portage doctor --json` ran; the index check reported "Index database: ...index.sqlite3 (0 store row(s), 0 product row(s), FTS5 available)". So the mise route already installs what this branch documents.
   - The branch's own gem (built with `gem build`, `gem install --user-install`) gave the same `--version` and doctor output.
   - **Finding: it needs a C compiler.** With only `ruby mise git`, both routes fail building `bigdecimal` (native extension on Ruby 3.4); with `base-devel` they succeed. `sqlite3` was not the problem. README says so. Whether Omarchy ships `base-devel` is unverified.
   - Container quirk, not a product issue: pacman's sandbox fails under qemu emulation (`seccomp` error), so the test script sets `DisableSandbox`.
4. **Real-host checks that do not apply:** none touched `~/.portage`; the scratch dir is `tmp/validate/p4/`.

**Skipped, honestly:**
- **ClawHub scan/dry run: not run.** `clawhub` is not installed, and running it via `npx clawhub@latest skill publish --dry-run` was blocked by the permission classifier as a possible public-surface action, so I did not retry it another way. Nothing was published. ClawHub's docs say `--dry-run` exists but does not check category slugs. **Still to do by the user:** run `npx clawhub@latest skill publish plugins/buy/skills/buy --slug <slug> --dry-run` (and, if wanted, a throwaway slug from the personal account) to see the real metadata-mismatch scan. The spec above is our stand-in for that scan.
- **OpenClaw runtime gating** (skill hidden when `portage` is missing): not run, no OpenClaw install here. The docs say skills are "filtered at load time based on ... binary presence"; not exercised.
- **Omarchy skill path: not verified.** A read of the Omarchy manual was blocked, so nothing Omarchy-specific is documented. README points to the agent's own skills directory instead.
- Headless `claude -p /buy` was not re-tried (the Phase 3 skip stands).

**Judgement calls:**
- **No existing plugin-version check existed** (searched Rakefile, script/, specs, CI), so "reuse the existing machinery" had nothing to reuse. The drift check is one spec, in the portage-cli suite because that is the only suite CI runs; it skips itself outside the monorepo.
- **The skill `version` is a second place to bump at release.** Cutting a release that bumps `plugin.json` must also bump SKILL.md `version`, or the spec fails (deliberately).
- **Shipping suffix vars are declared by name** (`PORTAGE_SHIP_CITY` etc.), because the skill lists them as `_CITY`... next to `PORTAGE_SHIP_STREET`. `PORTAGE_HANDOFF_TARGET` and the other flag-style vars are declared too, since ClawHub scans for any named var. Not declared: vars the skill never names (`PORTAGE_CURRENCY`, `WALMART_*`...).
- **`.env` and `config.json` under `requires.config`** as the plan said; they are optional in practice (portage runs without them and `doctor` reports gaps).
- **OpenClaw doc verified** its personal skills dir is `~/.agents/skills` (default state) and managed is `~/.openclaw/skills`, so the existing dotagents route already lands there.

**Bugs caught:** the first frontmatter draft failed YAML parsing (unquoted `: ` inside env var descriptions), which the parse spec caught before anything was validated elsewhere. A spec read the skill as US-ASCII in this shell locale (`invalid byte sequence`), fixed by reading as UTF-8.

### Omarchy validation (2026-09-30)

**Sources:** a clone of `github.com/basecamp/omarchy` at `8b4eae6` (2026-09-29), and a `linux/amd64` `archlinux:latest` container with Omarchy's own `bin/omarchy-mise-install` copied in, run as a non-root user.

**Omarchy's source:**
- **Base packages** (`install/omarchy-base.packages`) include `ruby` (3.4), `mise-bin`, `clang`, `llvm`, `git` and `yay`.
- **`base-devel` is only in `install/omarchy-other.packages`,** which the file describes as "installed outside of install/packages.sh or optional packages". Neither `gcc` nor `make` is listed. `gcc` still arrives, because `clang` depends on it (`/usr/sbin/gcc` was present in the container). `make` doesn't: nothing in the base list depends on it, and `yay`'s own dependencies are `pacman` and `git`.
- **CLI install.** Omarchy installs agent CLIs through `omarchy-mise-install <pkg> [command]` (`install/user/mise.sh`: `codex`, `claude`, `gh`, …). That writes a `~/.local/bin/<command>` wrapper which runs `mise use -g <pkg>` and then `mise x`. For Portage that is `omarchy-mise-install gem:portage-cli portage`.
- **Skill directories.** `bin/omarchy-provision-user` (and `docs/file-layout.md`) symlinks Omarchy's own skills into `~/.agents/skills`, `~/.claude/skills`, `~/.codex/skills`, `~/.pi/agent/skills`, `~/.gemini/config/skills` and `~/.hermes/skills`. So those are the directories the agents on Omarchy read.
- **OpenClaw** installs as the `openclaw` pacman package (`bin/omarchy-install-openclaw-cli`), not through mise.

**Container runs:**

| Setup | Result |
|---|---|
| Omarchy base (`ruby mise clang llvm git`) via `omarchy-mise-install gem:portage-cli portage` | **Fails**: `mise ERROR Failed to install gem:portage-cli@latest: gem exited with non-zero status`. The same packages with a plain `gem install` show the cause: `make failed No such file or directory - make`, building a native extension. |
| Base + `make` via `omarchy-mise-install gem:portage-cli portage` | **Pass**: `portage --version` gives `0.10.0`, and `portage doctor --json` parses (10 findings). |

**So:** a stock Omarchy needs `sudo pacman -S --needed make` (or `base-devel`) before installing. README's current "needs `base-devel`" is right but heavier than necessary, and it doesn't mention `omarchy-mise-install`. Phase 5 step 0 fixes the bullet. **Not verified:** a real Omarchy install (VM or ISO); OpenClaw hiding the skill when `portage` is missing.

### Phase 5 results (2026-09-30)

**Built:**
- **Step 0, README.** The Omarchy bullet now says `omarchy-mise-install gem:portage-cli portage` (plain `mise use -g gem:portage-cli` and brew stay as alternatives), `sudo pacman -S --needed make` for a stock Omarchy (the `base-devel` line is gone), and the skill directories `~/.agents/skills` (OpenClaw, dotagents), `~/.claude/skills` (plugin route preferred) and `~/.codex/skills`. "Could not verify" is dropped. The docs site includes this README block (`docs/skills/buy.md` uses include-markdown), so nothing else needed editing. Root CHANGELOG entry.
- **`script/categories`** (stdlib only: net/http, yaml, optparse). `--from FILE` or fetch from Google, `--out PATH`. It pins the edition (2021-09-21, read from the file's first line) in the header and is deterministic: the fetched file and the local copy gave byte-identical output. `CategoriesGenerator` is a module in the script so a spec can load it.
- **Data.** `known-stores/categories.yml` keeps all 213 ids, in the same order and with the same names. A level-2 node's `keywords` are its own name plus every descendant's (levels 3+), plus synonyms. Its parent's words go in `parent_keywords`. Level-1 nodes keep their own name only. `category-stoplist.yml` (32 words, each with its reason) and `category-synonyms.yml` (5 nodes, 6 words: `pendant`, `sconce`, `bollard` on Lighting; `whitegoods` on Household Appliances; `telco` on Communications; `boots` on Shoes) are shipped too, through the existing `known-stores/*.yml` gemspec glob.
- **Classifier.** `categories_for` keeps its signature (plus an optional `stoplist_path:`) and return shape. It is now three files: `classifier.rb` (tokenizing, `word_match?`, `names_for`), `classifier/table.rb` (loading both YAML files, the keyword -> node indexes, a cache keyed on each file's mtime and size so an edit to `~/.portage/categories.yml` still shows up) and `classifier/ranking.rb` (scoring). The split also keeps `Metrics/ModuleLength` and the complexity cops satisfied without a disable.
- **Specs.** `classifier_golden_spec.rb` (9), `categories_generator_spec.rb` (18, on `spec/fixtures/taxonomy_tiny.txt`), 37 new examples in `classifier_spec.rb`. The fixture `spec/fixtures/classifier_golden.yml` has 100 cases: 16 Light Yard storefront texts (product_type + tags, as `Mapper` builds them), 10 JB Hi-Fi storefront texts and 9 JB titles, 56 shopper queries (including the `find` spec queries `kettle`, `snowboard`, `kitchen knives`, `cold brew`, `boots` and the four Phase 2 failures), 9 browser-import style urls and page titles.

**Validation** (all in scratch dirs under `tmp/validate/p5/`; the real `~/.portage` was never written. The real `known-*.json` caches were copied into a scratch `HOME`):
1. **Golden-set top-1 accuracy** (100 cases, labels written from the products, not from the classifier):

   | State | Accuracy |
   |---|---|
   | Baseline (old code, old data) | 12/100 |
   | Generator + stoplist, old counting, list capped at 3 | 46/100 |
   | New scoring only, on the old data | 22/100 |
   | Generator + stoplist + new scoring, no synonyms (commit 3) | 56/100 |
   | + synonyms (commit 4, final) | 70/100 |

   The two middle rows are not commits: commit order was changed, see the judgement calls. The baseline is 12/100 with the final labels too (re-run against the old code and old data). `classifier_golden_spec.rb` holds the threshold at 0.70.
2. **`categories.yml` diff review.** 20,778 -> 101,155 bytes (1,263 -> 8,086 lines, 28.7KB gzipped). 213 ids, same order, same names. Ten nodes spot-checked, `keywords` old -> new: Lighting 594 (3 -> 36: lighting, emergency, floating, lights, flood, spot, lamps, ..., plus pendant, sconce, bollard), Hardware > Tools 1167 (2 -> 232), Sofas 460 (2 -> 1, `sofas`; parent `furniture`), Personal Care 2915 (3 -> 290), Audio 223 (2 -> 79), Communications 262 (2 -> 40 + telco), Toll Collection Devices 4488 (4 -> 2: toll, devices, so `collection` is gone), Kitchen & Dining 638 (4 -> 410), Shoes 187 (2 -> 2 + boots), level-1 Animals & Pet Supplies 1 (unchanged). The largest node has 474 keywords and the file 7,043 in all.
3. **Light Yard, `portage index search light --category 594`** on a copy of the Phase 2 index, then `index build --sources storefront_products` (a real re-crawl, 164 products): **1 of 164 before, 160 of 164 after.** The 4 misses are "Prestige LED Wall Light", "Black & Gold Bell Wall Light", "Eco Beacon Pillar Outdoor Wall Light" (Decor 696, through "wall") and "Orbital Industrial Floor Lamp" (Chairs 443). A plain re-crawl also fixed rows because `ProductStore` keeps the latest sighting's category.
4. **`find` routing on 7 queries** (`SearchBackends::Index#search`, which is what `find` asks the index backend, against the real known-stores cache in a scratch `HOME`; no network; old code from a worktree at the Omarchy commit):

   | Query | Before: categories -> routed stores | After: categories -> routed stores |
   |---|---|---|
   | bathroom pendant light | Bathroom Accessories -> pura.com, drift.co, kitsrepublic.com | Lighting, Bathroom Accessories, Jewelry -> the same 3 |
   | electric kettle | none -> 0 | Kitchen & Dining -> homecourt.co |
   | wireless headphones | none -> 0 | Audio -> 3 electronics stores |
   | mens hiking boots | none -> 0 | Outdoor Recreation -> 3 sport stores |
   | iphone 17 case | Handbags/Cases, Umbrella Cases, Train Cases -> 2 stores | Train Cases, Umbrella Cases, Handbags/Cases -> the same 2 (order swapped) |
   | queen mattress | none -> 0 | Linens & Bedding, Outdoor Recreation, Beds -> 6 stores |
   | samsung tv | none -> 1 (name match) | none -> 1 (same; "tv" is under the 3-letter minimum) |

   Nothing routes worse. The first full version of this gave "electric kettle" five furniture and office stores (Chairs and Signage matched "electric"), which would have crowded the web results out of `find`'s 12 probes; that is why the cut exists (judgement calls).
5. **Speed.** `categories_for` on a 40-word Light Yard tag text: 3.6ms before, 0.9ms now (a first version that rebuilt the keyword index per call took 21ms; the cache fixed that).

**Misses left** (30 of 100, in `classifier_golden.yml`; the threshold must only go up):
- Light Yard's odd texts: 3 "Wall Lights"/"Exterior Wall Lights" tag lists and 1 floor lamp ("wall", "floor" and room names pull Decor, Chairs or Power & Electrical above Lighting), plus the Light Yard product url.
- Ambiguous taxonomy: "sunglasses" (Personal Care ties Clothing Accessories), "dog food" (Food Service ties Pet Supplies), "55 inch television" (Film & Television beats Video), "paper towels", "scented candles", "red wine", "cold brew coffee", "queen mattress", "external hard drive", "road bicycle", "table lamp", "cordless drill" ("cordless" names Communications as strongly as "drill" names Tools).
- Brand and model strings with no product noun: the Corsair power supply, the X.One iPhone case, the LG "Vac", the Roborock, the Beko, the JBL headset (Chairs, through "gaming"), the Dyson page title, and "SMALL APPLIANCES" and "MUSIC" as bare product types.
- `shop.example/collections/sofa-beds` (Outdoor Furniture beats Sofas), plus the two JB urls that repeat the title cases.

**Judgement calls:**
- **Commit order.** The plan's order (generator, then scoring) cannot be green per commit: with the roll-up data and the old "count the keywords" scoring, `importer_spec` "weights categories by visit count" fails (Kitchen Knives fills the domain tally's top five). So the scoring commit came first (fixture-based specs, old data), then the generator and data, then synonyms. The table above still has the measured "generator first" number (46).
- **Scoring is more than 2/1, and the plan's IDF caveat applies.** 2/1 with distinct-word counting scored 39 on the golden set, so I went further, each step measured on the golden set and on the 164 real Light Yard products (top-1 is Lighting for how many):
  - *Repetition* (1 + ln count, plural variants merged): a Shopify tag list says "Pendant Lights" once per room, which is its best signal. Worth about +4 on the golden set.
  - *Tie-breaks*: the share of the node's own name covered ("Sofas" before "Sofa Accessories"), then a name with no stoplisted word, then fewer keywords, then file order. The plan said "ties unchanged". Worth roughly +10 together (39 to 52 before synonyms), because level-2 nodes tie constantly now. File order alone put "Sofa Accessories", "Pet Supplies" (for "treadmill") and "Handbag & Wallet Accessories" first.
  - *IDF* (ln(1 + nodes / nodes the word matches)): **not used for ranking.** Full IDF scored 67 (not 70) on the golden set and 146 of 164 on Light Yard (not 160), because a lighting store's tags are full of rare room names ("Hallway", "Study") that IDF promotes over "light". It is used only for the cut (below).
  - *The cut and the cap*: `categories_for` returns at most 3 ids, and after the first an id is dropped unless its rarity-weighted evidence is at least half the strongest. Without it, callers that treat every id as evidence (find routing, the browser-import tally) got 14 ids on average instead of 3 and "electric kettle" routed to furniture stores. The plan said the return shape stays; it does (still an Array of ids, most likely first), only shorter.
- **Level-1 nodes do not roll up descendants.** They keep their own name, so "Home & Garden" cannot outweigh every specific node.
- **Stoplist entries list both forms of a word** (`set`, `sets`) because it is matched exactly on both sides; the keyword match is what normalises plurals. `hand` (Light Yard tags 146 of 164 products "British Hand-Made", and it is 10 nodes' word) and `service`/`services` (JB "TELCO SERVICES") are on it because each flipped golden cases.
- **Only synonyms that flipped a case stayed.** `vac` and `iphone` did nothing for their own cases, so they were dropped; `telco` only worked once `services` was stoplisted. A spec checks that every synonym's reason is the exact text of a golden case of that category containing the word.
- **Two golden labels were corrected after the first commit** (external hard drive and the Corsair power supply are Electronics Accessories 2082, not Computers 278; `CAMERAS` is Cameras 142, not the level-1 parent 141). Both failed before and after, so the baseline of 12 is unchanged.
- **Existing rows: re-crawl to re-classify.** `index refresh` does not re-classify, and I did not add a command. `ProductStore#upsert` already keeps the latest sighting's `category`, so `portage index build --sources storefront_products` (or `index add URL --crawl`) re-tags a store's products, as the Light Yard run shows. It is documented under `index search` in `docs/api/cli-json.md` and in the portage-cli CHANGELOG. One caveat: a product that now classifies to nothing keeps its old category (`new || old`).
- **`Table` cache.** Keyed on each file's mtime and size rather than process-wide forever, because the file that used to be re-read on every call is now 100KB.
- **No existing spec expectation changed.** Every existing find, search_backends, index, importer and classifier spec passes as written. `importer_spec` "weights categories by visit count" is the one that depends on list length: it passes because the list is capped (3 ids, so the 10-visit title and the 1-visit title both fit in the tally's top five), and the order of equal weights in that tally comes from `sort_by`, which is deterministic here but not stable by contract. Worth a stable sort in `Categorize.domain` some day. (Done afterwards: see "Phase 5 follow-up results".)

**Bugs caught (by specs and by measuring):**
- `importer_spec` failed as soon as the roll-up landed (list length), which drove the cap.
- A relative cut using `round(6)` dropped an id at exactly half the best score (2.197224 against 2.197225); the "keeps an id scoring exactly half" spec caught it, and the old `boot shoe apparel` spec needs the same inclusive rule.
- The shipped stoplist applies to my own specs: `hand` and `set` silently removed words from spec inputs. Specs now use other words.
- The keyword-index rewrite was checked against `word_match?` over 14,314 variants of every shipped keyword (0 mismatches), and a spec keeps that equivalence.
- IDF in the ranking looked fine on short queries and made Light Yard worse (146 of 164 instead of 160); only measuring on the real products showed it.
- One JB Hi-Fi case (`WHITEGOODS Brand:Beko LimitedStock`) was in the golden set twice. It is replaced by a JB url case (`yaber-l1-pro-full-hd-projector` -> Video), in its own commit; it changed no number.

**Not done, deliberately:**
- `StorefrontProducts::Mapper` still classifies `product_type` + tags, not the title. JB Hi-Fi's product types are mostly noise ("MOVIES" for a puzzle), so its storefront categories stay weak. Adding the title is a separate one-line change with its own routing consequences. (The follow-up tried it in two forms and rejected both: see [Phase 5 follow-up results](#phase-5-follow-up-results-2026-09-30).)
- No re-classify command, no per-store refresh of categories.
- No title or description in `index search` FTS (unchanged).
- Tokens under 3 letters are still dropped, so "tv" and "pc" never match (as before).
- IDF in the ranking, and any bulk synonym list.
- The generator does not check the shipped `categories.yml` against a fresh run in a spec (the Google file is not in the repo). Re-run `script/categories` after editing the stoplist or synonyms.

### Phase 5 follow-up results (2026-09-30)

**Kept:** a stable sort in `BrowserImport::Categorize.domain` (ties on weight keep first-seen order: `each_with_index.sort_by { [-weight, seen] }`), with a new `categorize_spec.rb`.

**Tried and rejected:** classifying the title in `StorefrontProducts::Mapper`, in two forms. No mapper code, spec, doc or CHANGELOG change was committed.

**Measured** (raw `products.json` fetched once into `tmp/validate/p5f/raw/`: Light Yard 1 page, JB Hi-Fi 20 pages of 250, 1s pause, the project's User-Agent; 5,000 JB products. Old and new classification ran offline over the same pages. Scripts: `measure.rb`, `mapcheck.rb`, `labels.rb`):

| Measure | Old (type + tags) | A: title + type + tags | B: title only as a fallback (rejected in review) |
|---|---|---|---|
| Golden set (`Classifier.categories_for` on fixed texts) | 70/100 | 70/100 (not affected by a Mapper change) | 70/100 |
| Mapper-input view of the 26 storefront golden cases (titles joined back from the raw pages; **not** the golden accuracy) | 20/26 | 18/26 | 20/26 |
| Light Yard, first category = 594, of 164 | 160 | 142 | 160 |
| JB Hi-Fi sample top-1 (seed 42, 50 products, labels written before looking at any new output) | 22/50 | 14/50 | 25/50 |
| JB Hi-Fi products with no category (of 5,000) | 1,633 (32.7%) | 98 (2.0%) | 98 (2.0%) |

- **JB top-10 first category, old:** Decor 815, Communications 763, Computers 555, Cameras 308, Sheet Music 184, Outdoor Furniture 146, Audio 107, Small Engines 91, Games 73, Household Appliances 66.
- **JB top-10, new (B):** Decor 1031, Communications 766, Computers 566, Cameras 308, Sheet Music 184, Outdoor Recreation 181, Hobbies & Creative Arts 175, Outdoor Furniture 147, Audio 114, Puzzles 110. Decor grows by 216 and Puzzles enters the top ten; plain A instead put Food Items first (674 products), which is what a brand word in a title does.
- **Light Yard end to end:** `index add https://thelightyard.co.uk --crawl` in a scratch HOME (164 products, 1 page), then `index search light --category 594`: **160 of 164**, and 160 rows with `category` 594 in the database. The same as before.
- **B in the real Mapper, before it was dropped** (not just my scripts): JB sample 25/50, no category 98/5,000, Light Yard 160/164.

**Review measurements** (same raw pages and labels; these overturned B):
- **Precision of the fallback itself.** Of the 50-product JB sample, 20 fall back to the title: 3 are right, 16 wrong, 1 still none (Spigen phone cases go to Luggage & Bags > Train Cases; Desky desks to Apparel/Clothing, Decor and Outdoor Recreation; PLA filament to Food Items, Clothing and Hobbies; Ultra Pro card accessories to Office Supplies > Filing, Hardware > Tools and Personal Care). Precision of the categories assigned on the sample: old 22/30 (73%), B 25/49 (51%).
- **Store-row routing.** `Builder#merge_categories` tallies every sighting's ids into the store's top 5 (`TOP_CATEGORIES`), which `find` routing reads. JB old top 5: Decor 836, Communications 763, Computer Software 744, Digital Goods & Currency 556, Computers 555. JB with B: Decor 1132, Communications 770, Computer Software 768, **Sporting Goods > Outdoor Recreation 620**, Computers 582. After a crawl, "mens hiking boots" would route to JB Hi-Fi. Light Yard's top 5 is identical either way.

**Decision: neither form is kept; the code was not committed.**
- **A (title + type + tags)** regressed Light Yard (160 to 142 of 164) and the JB sample (22 to 14 of 50): a brand or model word in a title ("Apple", "Ultra Pro") outvotes a tag list that says what the thing is.
- **B (title only when type + tags match nothing)** passed the bars I set, but the bars were wrong (see the next paragraph): it fills gaps with mostly wrong guesses and pushes a wrong category into JB's store row.

**Judgement calls and bugs caught:**
- **My sample top-1 metric hid the regression.** It scored "no category" as a miss, so any guess could only raise it (22 to 25, and "no category" 32.7% to 2.0%, both looked like wins). Review caught it by measuring precision of the assigned categories and the store-row tally, which is what routing actually consumes. A no-category product is harmless (the store is routed by its other products); a wrong one is not.
- **The golden set was not touched** and could not move: it feeds `categories_for` fixed texts. It stays 70/100 and `minimum_accuracy` stays 0.70. The Mapper-input view of the 26 storefront golden cases (table above) is not the golden accuracy.
- **JB sample labels** are my judgement from title, type and vendor, written before looking at any new output. Some are arguable (MtG cards, smartwatch, LED Christmas lights).
- **The stable sort.** A random search found `sort_by` reordering equal keys only from 17 entries up (every smaller input stayed in order). The spec uses 17 categories with six tied at weight 3. Against the old code it failed with `expected: ["3", "4", "12", "13", "14"] got: ["16", "14", "3", "4", "13"]`. A tally that large is rare (the classifier returns at most 3 ids per text), so this is a correctness guard, not a fix for a seen bug.

**Existing spec expectations changed:** none.

**Not done, deliberately:** a title fallback that only fires on a confident title match (`categories_for` does not expose scores, so that needs a classifier change); or a per-store `product_type` noise rule (for example, ignore a type shared by an implausibly large and varied share of a store's products, as JB's "MOVIES" is). Either would need its own precision and store-row measurement, not top-1 accuracy alone.

## Next (for the user)

1. ClawHub dry run passed (clawhub 0.23.3): `portage-buy@0.8.0`, 4 files, slug free. The CLI ignores the frontmatter `version`, so pass it: `npx clawhub@latest skill publish plugins/buy/skills/buy --slug portage-buy --version 0.8.0 --name "Portage Buy"` from the personal account. The server-side scan only runs on a real publish. Nothing has been published.
2. Cut the release when you want it (open decision 4): bump `plugins/buy/.claude-plugin/plugin.json` **and** SKILL.md `version` together, CHANGELOG, `rake publish_all`, `rake homebrew:update`. The release carries the taxonomy pass (the gem ships the new `categories.yml`, the stoplist and the synonyms) and the browser-import tie-break from the Phase 5 follow-ups.
3. Still open: re-running the headless `/buy` card check on an authenticated session (Phase 3): `claude -p --setting-sources local --plugin-dir plugins/buy`, `portage` wrapper on PATH with a scratch HOME, `portage buy` disallowed.
4. Not verified, as before: a real Omarchy install (VM or ISO), and OpenClaw hiding the skill when `portage` is missing.
