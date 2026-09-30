# Local Catalogue: SQLite Index, Storefront Crawl, Product Cards, Packaging

**Status:** planned, not started
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

## Restart prompt (Phase 1)

```text
Read docs/plans/local-catalogue.md in full, then implement Phase 1 only (SQLite index store).

Setup: git checkout main && git pull --ff-only && git checkout -b local-catalogue. Commit the plan file first if it isn't committed yet.

Work per the project memory: delegate the phase to a Sonnet subagent (Agent tool, model: sonnet, foreground). Pass it the plan path, "Phase 1" and the branch. The main thread briefs and reviews only.

Rules: KISS, DRY, TDD (failing specs first, in portage-cli/spec/portage/cli/index/). Keep Index::Store/ProductStore public APIs unchanged. No price or stock in the index. 0600 file, raising writes. Stay on the UCP spec shapes. rake spec (rspec + rubocop) green, no new cop disables.

Before writing code: re-read index/{store,product_store,builder,known_cache,exporter}.rb and their specs, since line refs in the plan may have drifted.

Finish: run every Phase 1 validation item and record the results. Add a progress-log row to the plan (including judgement calls and any bugs a review caught). Commit on local-catalogue without pushing. Then write the Phase 2 restart prompt into the plan's "Restart prompt" section, replacing this one.
```
