# Local Catalogue: SQLite Index, Storefront Crawl, Product Cards, Packaging

**Status:** done (Phases 1-4). MIT-0 accepted (2026-09-30). Release cut and ClawHub publish are the user's, see "Next".
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

## Open decisions

1. Vendored SQLite vs `depends_on "sqlite"` in Homebrew. Phase 1 validation decides.
2. `index add` crawls by default or only with `--crawl`. **Decided in Phase 2: only with `--crawl`** (see "Phase 2 results").
3. MIT-0 on ClawHub. **Decided 2026-09-30: accepted.** The repo stays MIT; ClawHub republishes the skill as MIT-0.
4. Release cut (versions, CHANGELOG, `rake publish_all`, `rake homebrew:update`) after Phase 4, as its own step, only when asked.

## Progress log

| Date | Phase | Result |
|---|---|---|
| 2026-09-30 | plan | Drafted and validated against the code, live `products.json`, the `sqlite3` gem platforms, ClawHub skill-format docs and `mise ls-remote gem:portage-cli`. |
| 2026-09-30 | 1 | **Done** (commits `Store the local index in SQLite`, `Report the index database in portage doctor`; unpushed). `rake`-equivalent for portage-cli: rspec 1103 -> 1131 examples, 0 failures; rubocop clean, no new disables. Existing `store_spec`/`product_store_spec` pass unchanged. See "Phase 1 results" below the table. |
| 2026-09-30 | 2 | **Done** (commits `Classify long texts without comparing every word to every keyword`, `Crawl a Shopify store's products.json into the local index`, `Add portage index search and page index show --products`, `Document the catalogue crawl and index search`; unpushed). portage-cli rspec 1131 -> 1201 examples, 0 failures; rubocop clean, no new disables; each commit green on its own. `index add` crawls only with `--crawl`. Live: thelightyard.co.uk 164 products in 3.5s, JB Hi-Fi 5,000 (page cap) in 36s, re-crawls upsert with no duplicates. See "Phase 2 results".
| 2026-09-30 | 3 | **Done** (commits `Carry the UCP product on find offers and index search hits`, `Document product cards in the buy skill and CLI reference`; unpushed). portage-cli rspec 1201 -> 1211 examples, 0 failures; rubocop clean, no new disables. `find` and `shopify_catalog` offers carry `product`; `index search` is `live: false` with a price-free `product` per hit. `claude plugin validate .` passes. Headless `/buy` run **skipped** (claude -p: "OAuth session expired"), replaced by a manual render check on real `find --json`. See "Phase 3 results".
| 2026-09-30 | 4 | **Done** (commits `Add OpenClaw metadata to the buy skill and check it against the plugin`, `Document installing the buy skill on OpenClaw and Omarchy`; unpushed). portage-cli rspec 1211 -> 1218 examples, 0 failures; rubocop clean. `claude plugin validate .` passes. Arch container: `mise use -g gem:portage-cli` gives a working `portage --version`/`doctor --json` (needs a compiler). **Skipped:** ClawHub dry run/scan (blocked, nothing published), OpenClaw runtime gating, Omarchy skill path (unverifiable). See "Phase 4 results".

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

## Next (for the user)

1. ~~Decide MIT-0~~ Accepted 2026-09-30 (open decision 3).
2. ClawHub dry run passed (clawhub 0.23.3): `portage-buy@0.8.0`, 4 files, slug free. The CLI ignores the frontmatter `version`, so pass it: `npx clawhub@latest skill publish plugins/buy/skills/buy --slug portage-buy --version 0.8.0 --name "Portage Buy"` from the personal account. The server-side scan only runs on a real publish. Nothing has been published.
3. Cut the release when you want it (open decision 4): bump `plugins/buy/.claude-plugin/plugin.json` **and** SKILL.md `version` together, CHANGELOG, `rake publish_all`, `rake homebrew:update`.
4. Unrelated leftovers: category keywords in `known-stores/categories.yml` (Phase 2), and re-running the headless `/buy` card check on an authenticated session (Phase 3).

