# Local Catalogue: SQLite Index, Storefront Crawl, Product Cards, Packaging

**Status:** Phase 1 done, Phase 2 next
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
2. `index add` crawls by default or only with `--crawl`. Decided in Phase 2.
3. MIT-0 on ClawHub. The user decides before the Phase 4 publish.
4. Release cut (versions, CHANGELOG, `rake publish_all`, `rake homebrew:update`) after Phase 4, as its own step, only when asked.

## Progress log

| Date | Phase | Result |
|---|---|---|
| 2026-09-30 | plan | Drafted and validated against the code, live `products.json`, the `sqlite3` gem platforms, ClawHub skill-format docs and `mise ls-remote gem:portage-cli`. |
| 2026-09-30 | 1 | **Done** (commits `Store the local index in SQLite`, `Report the index database in portage doctor`; unpushed). `rake`-equivalent for portage-cli: rspec 1103 -> 1131 examples, 0 failures; rubocop clean, no new disables. Existing `store_spec`/`product_store_spec` pass unchanged. See "Phase 1 results" below the table. |

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

## Restart prompt (Phase 2)

```text
Read docs/plans/local-catalogue.md in full, then implement Phase 2 only (storefront catalogue crawl and `index search`). Phase 1 (SQLite index store) is done on the local-catalogue branch; read its progress-log row first.

Setup: git checkout local-catalogue (Phase 1 is committed there and unpushed, so don't branch off main). Confirm `git log --oneline` shows the two Phase 1 commits ("Store the local index in SQLite", "Report the index database in portage doctor") and that `cd portage-cli && bundle exec rspec` is green before you start.

Work per the project memory: delegate the phase to a Sonnet subagent (Agent tool, model: sonnet, foreground). Pass it the plan path, "Phase 2" and the branch. The main thread briefs and reviews only.

Rules: KISS, DRY, TDD (failing specs first, in portage-cli/spec/portage/cli/index/**). Map products.json into Portage::Ucp::Product, don't invent a parallel shape. Price and availability are dropped before persisting. Classifier for taxonomy, Support::Connection and UserAgent for HTTP, HandoffOnly checked before any request. WebMock fixtures, no live HTTP in specs. rake spec (rspec + rubocop) green, no new cop disables.

Phase 1 facts to build on (verify in the code, they may have drifted):
- Index::Database (index/database.rb) owns ~/.portage/index/index.sqlite3; Index::Schema (index/schema.rb) holds forward-only MIGRATIONS (user_version). Add a migration there for any new table or column, never edit an existing one.
- ProductStore#upsert_many(rows) takes hashes with key:, origin:, seen_at: plus the same fields as #upsert, in one transaction. Use one call per page of the crawl. Builder still calls #upsert per sighting; move it to upsert_many only if it is a trivial swap.
- products_fts (FTS5: title, brand, category, aliases; rowid = products.id) and product_stores are kept in step by SQL triggers on the products table, so new entry fields are stored in the JSON `data` column with no extra indexing code. Adding a field to FTS means a new migration that drops and recreates the fts table and triggers. FTS5 can be missing on a system-libraries SQLite build (Schema.fts5_available?), so `index search` must degrade to a clear error or LIKE fallback, not crash.
- Database#execute(sql, binds) is the escape hatch for search queries. Database#transaction is reentrant.
- Legacy stores.json/products.json import happens only on the open that creates the database.

Before writing code: re-read index/{database,schema,store,product_store,builder}.rb, index/sources.rb, index/sources/*.rb, the Ucp::Product/Variant value objects, Classifier and the SearchBackends::Index backend, plus their specs, since line refs in the plan may have drifted.

Finish: run every Phase 2 validation item (live crawl of thelightyard.co.uk and one large Shopify store, with timings and counts; `index search` sanity) and record the results, including failures and skips. Add a progress-log row to the plan (judgement calls, bugs a review caught, the `--crawl` decision). Commit on local-catalogue without pushing. Then write the Phase 3 restart prompt into the plan's "Restart prompt" section, replacing this one.
```
