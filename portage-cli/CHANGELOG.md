# Changelog

All notable changes to this project are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.0.0/); this project is
pre-1.0, so APIs may still shift between minor versions.

## [Unreleased]

## [0.12.0] - 2026-10-01

- **Release note: the confidence check wants `portage-ucp-decision` 0.1.2.** `portage-ucp-decision` stays an optional install, not a dependency, but 0.1.2 is the version that rejects a malformed backend answer (see its changelog); the README says so.

- **`find --store URL --query Q [--max-price N]` searches one store, live.** The index-search hint, the `buy` skill and the docs already told agents to re-check an index hit this way, but `find` had no `--store`. It now skips the search backends and retailer offer sources and probes and searches only that store's catalogue (read-only: never a cart or checkout), with offers, `offer_ref`, `search_id` and the history entry shaped like any find, so `pick` and `buy --offer` work on them. A hand-off-only host is never fetched and is reported as such; a store without UCP is reported as having no catalogue; a non-http(s) URL is a usage error. The index-search hint now reads `find --store URL --query ...`.

- **Security: a priced line nobody asked for is a checkout mismatch.** `buy` requests exactly one
  line, but only checked that line, so a store that added an upsell, a "shipping protection"
  add-on or a second copy of the item (or, on a WebMCP cart, whatever was already in the store's
  cart) still went through. Any other line now stops a real run with `checkout_mismatch` ("Store
  added ... to checkout, which wasn't requested."), and a dry run flags it with
  `checkout_mismatch: true`. An extra line that costs nothing (its own total, or its unit price
  times quantity, is 0) is allowed, so a free gift or $0 sample doesn't block a purchase; one
  whose cost can't be read counts as priced.

- **Security: the confidence check sends an allowlisted summary, and compares against the
  approved quote.** The state sent to the decision backend (`PORTAGE_DECISION_BACKEND`, e.g.
  `jev`, TypeSafe's hosted API) used to be a slice of the raw checkout hash, so whatever a store
  nested under `line_items` or `totals` went along with it. It is now built field by field by the
  new `Portage::Cli::ConfidenceState`: the request (query, store host, quantity, picked item id
  and title), on a `buy --quote` run the approved quote (store, product id, title, quantity,
  total, currency), and the checkout's status, currency, per-line item id, title, unit price,
  quantity, totals and whether it's the requested line, the totals (shipping, tax, fees included),
  applied discounts' titles and amounts and the selected shipping option's title and price, plus
  `warnings`. Never the payment token, the address, the buyer's name, phone or email, ids, links,
  discount codes or environment values; store strings are cut to 200 characters. The question
  now asks the model to say yes only when the checkout matches the request and the approved
  quote. `Buy.new` takes `quote_store:` and `quote_title:`, which `buy --quote` passes from the
  saved quote. The check stays additive: it only sees a checkout the mismatch check, the quote
  cap and the spend policy let through, and can hold it but never let through one they stop.

- **Security: the non-preset WebMCP hand-off runs the confidence check too.** A page whose WebMCP
  tools build a checkout (no preset, so `buy` ends in `express_stop` through `finish_checkout`)
  applied the quote cap and the mismatch stop but not the opt-in confidence check. With a decision
  backend enabled it now runs before the hand-off, after those two. A hold reports `low_confidence`
  with the store's `/cart` page as `checkout_url`, as the preset flow's does, and nothing is handed
  to the checkout (a `profile` target is not navigated there). A backend error holds the same way.
  No backend enabled: unchanged.

- **Security: the WebMCP hand-off flow runs the quote cap and the confidence check.** Against a
  page whose preset opens checkout through its own tool (Shopify's `proceed_to_checkout`), `buy`
  now checks, before that tool runs and before autofill: a `--quote` run's cap (`quote_changed`,
  never handed off; this flow never checked the quote before), the mismatch check, then, when a
  decision backend is enabled, the confidence check. A hold reports `low_confidence` with the
  store's `/cart` page as `checkout_url`; checkout isn't opened and nothing is autofilled. A
  backend error holds the same way.

- **Security: a quote with no total refuses instead of buying uncapped.** `buy --quote` capped the
  checkout at the quote's total only when the quote had one. A quote saved from a dry run with no
  priced total (a WebMCP preset dry run never has one) set no cap at all, so its `--yes` run
  bought at whatever the store asked. It now ends in `quote_changed`, saying the quote has no
  total, and nothing is bought or handed off.

- **Security: a checkout mismatch always stops the purchase.** `buy` used to stop on a checkout
  that didn't match the request (the item dropped, another quantity, another unit price) only under
  `PORTAGE_ABORT_ON_CHECKOUT_MISMATCH`. Without it the mismatch was a `warnings` entry and the
  purchase went ahead, so a real `--yes` run could pay for the wrong checkout and report
  `purchased` (reported by ClawHub's security audit of the `portage-buy` skill). Now every
  mismatch on a run that isn't `--dry-run` escalates (`decisions.escalation.reason: "mismatch"`)
  and ends in `checkout_mismatch` before the payment token, policy and completion are reached. The
  quote it ran under is spent, so the person dry-runs again for a new one. There is no opt-out:
  `PORTAGE_ABORT_ON_CHECKOUT_MISMATCH` is deprecated and ignored, whatever its value. A
  `--dry-run` keeps its `dry_run` outcome and `warnings`, and now adds `checkout_mismatch: true`
  and says in `message` that a real run would stop. The check also compares currency: a checkout
  in another currency than the catalog's price is a mismatch. The quoted total and currency are
  still `--quote`'s `quote_changed` check, unchanged.

- **Security: the WebMCP hand-off flow stops on a mismatched cart too.** Against a WebMCP page
  whose preset opens checkout through its own tool (Shopify's `proceed_to_checkout`), `buy` read
  the cart back and checked it, but only put a mismatch in `warnings`: it still called the hand-off
  tool, sending the browser tab to the store's checkout, and ran autofill there when it was
  approved. Now any mismatch stops the run before that tool, with outcome `checkout_mismatch` and
  `decisions.escalation.reason: "mismatch"`. Nothing is autofilled, and `checkout_url` is the
  store's `/cart` page, so the shopper can look at the cart that was built. A matching cart hands
  off as `express_stop`, as before. The dry run of this flow builds no cart, so it can't check one
  and never carries `checkout_mismatch: true`.

## [0.11.0] - 2026-10-01

- **Category classification uses the whole taxonomy.** `known-stores/categories.yml` is now generated
  by `script/categories` (stdlib only) from Google's product taxonomy, edition 2021-09-21, instead of
  coming from a script that was never committed. It keeps the same ids and the same top-two-level keys
  (so `~/.portage/categories.yml` overrides still work), but a level-2 node's `keywords` now include
  its descendants' names ("Chandeliers" counts for Lighting), and its parent's words sit in a separate
  `parent_keywords` list. The file grows from 20KB to 101KB. A shipped stoplist
  (`known-stores/category-stoplist.yml`, every word with its reason) removes merchandising and url words
  ("new", "collection", "sale", "gift", "accessories", "products", ...) from both the data and the input,
  and a small synonyms file (`category-synonyms.yml`, each word tied to a golden case) adds the few
  words the taxonomy lacks ("pendant", "sconce"). `Classifier.categories_for` keeps its signature (plus
  an optional `stoplist_path:`) and returns at most three ids, best first. Scoring: a keyword counts
  2 and a `parent_keyword` 1, times how often the input repeats the word (1 + ln count) and, for the
  cut, how rare it is. A word counts once per node, and an id scoring under half the strongest is
  dropped. Ties go to the node whose own name the input covers most, then to one whose name has no
  stoplisted word, then to the smaller node. On a 100-case golden set (Light Yard, JB Hi-Fi, shopper
  queries, browser-import titles and urls) top-1 accuracy goes from 12% to 70%. "Pendant Light" is
  Lighting, "New Collection" is no longer Toll Collection Devices, and 160 of Light Yard's 164 products
  classify as Lighting (1 before). Products already in the index keep the category they were crawled
  with: crawl the store again (`portage index build --sources storefront_products`) to re-classify them.
- **The local index is now a SQLite file.** `~/.portage/index/index.sqlite3` (mode 0600, WAL)
  replaces `stores.json` and `products.json`, through the new `sqlite3` gem dependency (`~> 2.9`,
  precompiled for macOS and Linux). An existing `stores.json`/`products.json` is imported once on
  first use and renamed to `*.json.migrated`; it is never deleted. `Index::Store` and
  `Index::ProductStore` keep their APIs, and `ProductStore#upsert_many` writes a batch in one
  transaction. Index write failures now raise instead of being dropped. `portage doctor` reports the
  database path, row counts and whether FTS5 is available. The known-stores cache and `index export`
  output stay JSON.
- **Storefront catalogue crawl and `portage index search`.** A new opt-in index source,
  `storefront_products`, reads a Shopify store's public `/products.json` into the local index. Run it
  with `portage index add URL --crawl` for one store, or `portage index build --sources
  storefront_products` for stores already indexed (25 a run, least recently crawled first). Each
  product is mapped through the UCP `Product` shape and stored with its handle, URL, first image,
  options and variant ids. Price and availability are dropped before anything is written. A crawl
  reads at most 20 pages of 250 a store, 1s apart. It waits out one 429's `Retry-After` (capped at 60s)
  and stops on a second, and it obeys `robots.txt` for every page URL. It never contacts a hand-off-only
  host, and it skips a 404, a redirect or a non-JSON answer (a bot wall). What happened is kept on the
  store entry as `crawl`. `portage index search QUERY [--category ID] [--store HOST] [--limit N]
  [--json]` searches the index locally with SQLite FTS5, ranked by bm25, and sends no request. Without
  FTS5 it falls back to an unranked text match and reports `engine: "like"`. `index show --products` now
  pages (`--page N`, `--per-page N`, default 50). `portage check` suggests the `index add ... --crawl`
  command for a Shopify or native-UCP store (`index_hint`) but never runs it. `find` and `buy` never
  crawl.
- **Product cards for agents.** `find` offers (and `shopify_catalog` offers) gain a `product` field:
  the store's UCP `Product` wire hash as served, with `media` cut to the first image, so an agent or
  UI can draw a card without another request. The flat fields (`title`, `amount`, `currency`, `url`,
  `product_id`, `store`) are unchanged, the retailer API sources leave `product` out, and `history`
  does not save it. `portage index search` results are marked `live: false` and each hit gains
  `product`, built from the fields the index keeps (title, handle, URL, first image, options, variant
  ids, category), never a price. Text output says the hits are not live.

## [0.10.0] - 2026-09-29

- **`portage check <url> [--json]`.** Reports whether Portage can buy from a store and
  how: `verdict` (`automated`, `webmcp`, `handoff`, `unsupported`), `next_step`, and the
  detail behind them (native UCP, platform, adapter install and missing env, hand-off-only,
  WebMCP status). Wraps `Portage::Ucp::Check` and follows the precedence `buy` uses.
  Plain GETs only, hand-off-only hosts are not contacted, and WebMCP is read only from an
  already-open Portage profile tab. Exits `0` for `automated` and `webmcp`. The hand-off-only
  test moved into a shared `HandoffHost` so `buy` and `check` can't disagree.
  Follows a homepage `<link rel="ucp">` manifest pointer through `portage-ucp` 0.11.0,
  which this release now requires (`~> 0.11`).

## [0.9.0] - 2026-09-29

- **Human pick and approve** (`docs/plans/human-pick-and-approve.md`, Phases 1-3).
  Loop steps 3 and 5 now have a ready-made interface for a person at a terminal
  and for an agent relaying their answer.
  - **Offer refs.** Each `find` offer carries an `offer_ref` (`of_` and 6 hex
    digits), and the report a `search_id` (`se_` and 8 hex digits). Both are saved
    with the search in history, so `history --json` searches now hold `search_id`
    and `offers[]`. `compare` saves its offers with refs and a `search_id` too.
    `portage buy --offer REF` takes the store, product and query from the saved
    offer; an unknown ref is `offer_not_found`.
  - **Quotes.** A `buy --dry-run` that priced a checkout saves a quote in
    `~/.portage/quotes/` and reports `quote_id`. `buy --quote QUOTE_ID --yes`
    buys exactly that quote, capped at the quoted total: if the real checkout costs
    more (or is in another currency) it refuses with `quote_changed`, carrying
    `quoted_total` and `current_total`, without charging or handing off. Quotes don't
    expire and are used once (`purchased` or any hand-off). `quote_not_found` and
    `quote_used` cover the rest.
  - **`portage pick`.** Loop step 3. `needs_pick` returns `choices[]` (`ref`, `label`,
    `url`, plus the offer's fields) and a last "Compare an offer across stores"
    choice; `--choose REF` relays an answer (`picked`, `by: "agent_relayed"`),
    `--compare REF` runs compare and shows the pick again over its results,
    `--search LAST|SEARCH_ID` picks the search. At a terminal it asks on `/dev/tty`
    (`by: "person"`).
  - **`portage approve QUOTE_ID`.** Loop step 5. `needs_approval` returns a
    `summary` (title, store, qty, total, `total_display`, `url`); `--relayed-yes`
    records `approved_by: "agent_relayed"`; a yes typed at a terminal records
    `"person"`. The quote also keeps `approved`, `approved_by` and `approved_at`.
  - **`--via auto|tty|agent`.** `tty` asks on `/dev/tty` (so it works with stdout
    piped) and returns `no_terminal` when there's none; `agent` asks nobody;
    `auto` is `tty` with a terminal and no `--json`, else `agent`.
  - **`--view REF` / `approve --view` and `v N` / `v` at a prompt** open the product
    page and never count as an answer. Only an `http(s)` URL on the offer's own
    store host is opened; anything else is `view_refused`. `pick`'s compare
    choice uses the proxy settings from env and config (there are no `--proxy`
    flags on `pick`).
  - **`policy set --require-approval person|any|off`** (default `any`, stored as
    `require_approval` in `~/.portage/policy.json`, always shown by `policy show`).
    Lowering it needs a yes typed at a terminal. It raises the bar against an agent
    but isn't a hard guarantee: a process with a shell can edit the policy or quote
    files. Docs: `docs/api/cli-json.md`, `docs/agentic-flow.md`,
    `docs/cli-usage-tutorial.md`.
  - **Upgrade note.** Under the default `any`, a `buy --yes` without an approved
    `--quote` no longer buys: it dry-runs and returns `needs_approval` (exit `0`).
    Restore the old behaviour with `portage policy set --require-approval off`
    from a terminal. `buy --query`'s numbered pick now asks on `/dev/tty` too.

- Documentation only, no code change. The README said a
  `webmcp_mapping_unconfirmed` report returns the proposed mapping "for the
  caller to pass back". No flag takes a mapping back, and `Buy` has no
  `tool_names:` keyword. The README now says what each caller can do. From
  the CLI, re-run the command in a real terminal without `--json`
  (`--dry-run` is enough) and answer the prompt; the approved mapping is
  saved to `~/.portage/webmcp_mappings.json`. From Ruby, inject
  `webmcp_mapping_confirm:` or `webmcp_mappings:`, or pass `tool_names:` to
  `WebMcp.connect` yourself.

## [0.8.0] - 2026-09-29

- **Requires `portage-ucp-webmcp` 0.2.0 or newer for WebMCP paths.**
  `Webmcp.available?` now treats an older install as not installed
  (`Webmcp::MIN_VERSION`), since `WebMcp::Autofill`, `Presets`, `Matcher`
  and `Fingerprint` first shipped in 0.2.0. With 0.1.1 installed, the
  profile hand-off falls back to showing the link instead of raising a
  `NameError`.

- **`find --max-price` now filters offer-source offers too.** Offers from
  `OfferSources` (`ShopifyCatalog`, the retailer APIs) skipped the
  `--max-price` check that probed stores' offers go through, so a
  `--max-price 150` search could list a £190 catalog offer. Unpriced offers
  still stay in, as before. `find`'s summary also counts stores from the
  offers themselves ("Found 1 offer(s) across 1 store(s)."), not just the
  probed ones, which reported "0 UCP store(s)" for catalog-only results.
  Both found by the clean-session `/buy` check.
- **Docs release for Phases 1-7** (`docs/plans/buy-skill-and-local-browser.md`
  Phase 8). `README.md` here gains full documentation of everything the
  above entries shipped that wasn't written up yet: the usage banner now
  lists `index`, `browser import`, `browser profile` and `setup`; new
  sections cover Tiers A/B/C, `--handoff-target`/hand-off-only hosts (now
  reflecting Phase 6's built `profile` target and Phase 7's retail hosts),
  categories/routing, the local store index and its sources, browser
  import, the Portage browser profile, the five retailer offer source env
  vars, and the `setup` wizard's step order; the Search backends table
  gains the `Index` backend and a note on `OfferSources` merging offers
  directly. `Doctor`'s bullet list documents the `index`/`handoff`/
  `retailer_offer_sources` findings added in Phases 2b/5/7. No code
  changed.
- **Retailer offer sources, hand-off only** (`docs/plans/
  buy-skill-and-local-browser.md` Phase 7). `Portage::Cli::OfferSources`
  gains five official, opt-in buyer-side retailer APIs alongside
  `ShopifyCatalog`: `WalmartAffiliate`, `EbayBrowse` (Buy It Now only —
  `filter=buyingOptions:{FIXED_PRICE}`, checked again in code, and never
  eBay's Order API/guest checkout, which takes raw card data),
  `BestBuyProducts`, `EtsyListings` (Etsy Open API v3's
  `findAllListingsActive`, the *buyer*-side surface — `portage-ucp-etsy`
  stays the seller-side adapter, untouched) and `AmazonCreators`. Each is
  gated on its own key/token env var (`WALMART_AFFILIATE_API_KEY`,
  `EBAY_BROWSE_ACCESS_TOKEN`, `BESTBUY_API_KEY`, `ETSY_LISTINGS_API_KEY`,
  `AMAZON_CREATORS_ACCESS_TOKEN`), `#available?` false and silently
  excluded from `OfferSources.default` with none set — a fresh install's
  `find` is unchanged. Every request goes through
  `Portage::Ucp::Support::Connection` (via `SearchBackends.get_json`,
  never raw `Net::HTTP`), 5s timeout, failures swallowed exactly like
  `ShopifyCatalog`. None of the five is wired into `Index::Sources`, so
  nothing they return is ever written to `~/.portage/index/
  {stores,products}.json` — the plan's "honour each API's caching terms,
  default to not persisting" is enforced by simply having no code path
  that would.
  **Amazon PA-API vs. Creators API (live web search, 2026-09-28):**
  PA-API 5 is deprecated, retiring 2026-05-15 (already past), no longer
  onboarding new integrations; Creators API is its OAuth2 successor.
  `AmazonCreators` targets Creators API's search endpoint with a
  user-supplied bearer token (no OAuth dance or refresh implemented here,
  same "bring your own token" posture `EbayBrowse` uses for eBay's
  Application Access Token) and reads the long-stable PA-API
  `SearchItems`/`GetItems` item shape (`ASIN`/`DetailPageURL`/
  `Offers.Listings[0].Price`), which Amazon's own docs describe Creators
  API as continuing — **not live-checked**, no Associates account
  available this session; a schema mismatch only drops an offer
  (`#offer`'s nil guard), never a purchase-automation risk, since Amazon
  is already Tier C.
  Every offer ends in hand-off, never a completed purchase. Amazon
  already routed through the existing Tier C `HandoffOnly` path
  unchanged. `Buy#handoff_only?` now also checks
  `OfferSources.retail_handoff_host?` (walmart.com/ebay.com/bestbuy.com,
  unconditional — no adapter, no UCP, not a user-editable policy choice)
  and a new `#etsy_buyer_host?` (etsy.com, *unless* the process already
  has its own `ETSY_ACCESS_TOKEN`/`ETSY_API_KEY`/`ETSY_SHOP_ID` set, in
  which case the existing `portage-ucp-etsy` seller-adapter flow still
  applies unchanged) — every one of these hosts is checked before a
  single UCP probe or homepage fetch, same "never even scraped" guarantee
  Amazon already had. `handoff_only_checkout_url` returns the exact URL
  passed to `portage buy` for these hosts (the real product page a
  retailer offer source found), rather than falling back to the origin
  homepage the way an unknown Tier C host still does.
  `portage setup` gains an eighth, opt-in wizard step (`Steps::
  RetailerKeys`, between search keys and the agent profile) for the five
  keys, written to `~/.portage/.env`, never echoed back. `portage doctor`
  gains a `retailer_offer_sources` finding (always info) naming which are
  active and restating that none of them can complete a purchase.
  **Open question 3 resolved:** kept in `portage-cli`'s `OfferSources`
  (one class per retailer, one file), not split into per-retailer gems or
  a `portage-ucp-retail` gem — Phase 1's seam (`OfferSource#offers`) is a
  small interface with no adapter-style `Client`/`Adapter` pair to split
  out, each source is ~50-70 lines with no shared state beyond
  `OfferSources.origin_of`, none of them completes a purchase (the usual
  reason an adapter earns its own gem — its own `Client`/credentials/
  fulfillment logic), and a separate gem per retailer would mean five new
  `require`/`rescue LoadError` seams for zero behavioral gain over the
  `#available?` opt-in gate already in place. Revisit only if a future
  phase adds real purchase automation for one of these.
  `plugins/buy/skills/buy/SKILL.md`, `references/outcomes.md` and
  `references/handoff-only.md` updated; `plugins/buy/.claude-plugin/
  plugin.json` bumped to `0.6.0`. `claude plugin validate .` and `claude
  plugin validate plugins/buy` still pass.
  `portage-cli`: 925 → 961 examples (+36), 0 failures; `rubocop` clean, no
  new cop disables. **Not live-checked at all** (docs/plans/
  buy-skill-and-local-browser.md Phase 7 rule: "you almost certainly have
  no API keys"): every source's spec stubs the HTTP boundary with WebMock,
  none of Walmart/eBay/Best Buy/Etsy/Amazon Creators was called for real,
  and no real cart was touched anywhere.
- **Portage browser profile** (`docs/plans/buy-skill-and-local-browser.md`
  Phase 6, Tier B). `portage browser profile init|open|status [--browser
  chrome|edge|brave|arc] [--port N] [--url URL (open only)] [--json]`
  manages a dedicated Chromium-family profile directory under
  `~/.portage/browser/<browser>/profile`, launched with remote debugging
  bound to that profile only — never the browser's own default profile
  (`init!` only ever creates its own directory; `Launcher` only ever
  passes that directory as `--user-data-dir`; Chrome 136+ refuses remote
  debugging on the default profile anyway). `open` launches the browser
  if it isn't already running on its own port, waits for its CDP endpoint
  to answer, then attaches to an existing tab or opens a new one at
  `--url`; `status` reports `/json/version`; the user signs into their
  shopping sites in this profile once — nothing here ever reads a
  credential, cookie or autofill store from it.
  `--handoff-target profile` now actually does something: `Cli.
  run_buy`/`execute_buy` attaches a `Portage::Cli::BrowserProfile::Bridge`
  as `Buy#webmcp_bridge` whenever `portage-ucp-webmcp` is installed and
  the profile is running (`Cli.profile_webmcp_bridge`) — reusing an
  existing tab already on the store's host, or opening a new one — so
  `#webmcp_flow` (`docs/plans/webmcp-universal-outbound.md`) drives that
  same browser, and Phase 3's `WebMcp::Autofill` runs in it unchanged
  (`Bridge#headless?` is always `false`, so `autofill_needs_headed_browser`
  never fires for this profile — asserted directly). `Buy#dispatch_to_target`'s
  `"profile"` case now navigates the attached bridge to the checkout URL
  and reports `opened: true`, or — no bridge attached (gem missing,
  profile not running) — tells the shopper to run `portage browser
  profile open` first, same "report, never raise" posture as every other
  hand-off dispatch.
  Driving is limited to a domain allowlist (`Portage::Cli::BrowserProfile::
  Allowlist`, reusing `HandoffOnly`'s own host normalization/matching):
  seeded with the store's own host, and permitted to include a checkout
  host only when `Bridge#navigate` deliberately opens it — a page-driven
  navigation to anything else raises `DomainNotAllowedError` on the very
  next driven call (there's no navigation-event hook in this minimal a
  CDP client, so it's caught on next use, not mid-navigation), which
  `Bridges::ScriptEvaluator#evaluate` re-wraps as its own `BridgeError` —
  still caught by `Buy#webmcp_flow`'s existing rescue, so the run stops
  the same way any other WebMCP failure does. `Portage::Cli::BrowserProfile::
  CdpSocket` is a small, dependency-free WebSocket JSON-RPC client (RFC
  6455 handshake, masked outbound / unmasked inbound frames) for Chrome
  DevTools Protocol's `Runtime.evaluate`/`Page.navigate`/`Page.enable`;
  `Portage::Cli::BrowserProfile::Cdp` covers the plain-HTTP half
  (`/json/version`, `/json/list`, `/json/new`). No raw card data is ever
  read or typed by any of this; Portage never touches a payment field and
  never clicks pay. `portage-cli`: 865 → 925 examples (+60), 0 failures;
  `rubocop` clean (one documented `Metrics/ClassLength` exclude for
  `CdpSocket`, same "one small self-contained protocol end to end"
  rationale already given to `Index::Builder`/`BrowserImport::Importer`).
  Specs never launch a real browser or open a real socket — `Process.spawn`
  is injected (`Launcher`), CDP HTTP calls go through WebMock
  (`Portage::Ucp::Support::Connection`, same as every other network call
  in this gem), and the WebSocket layer is proven against an in-memory
  fake transport (`cdp_socket_spec.rb`), including RFC 6455's own §1.3
  worked handshake example.

- **Hand-off targets + hand-off-only hosts** (`docs/plans/
  buy-skill-and-local-browser.md` Phase 5). `portage buy --handoff-target
  default|print|profile|agent:<name>` (also `PORTAGE_HANDOFF_TARGET` /
  `~/.portage/config.json`'s `"handoff_target"`, same precedence as every
  other `Setting`) decides where a dead-end `checkout_url` goes:
  `default` is today's `CheckoutHandoff` auto-open, unchanged; `print`
  just reports the URL; `profile` is accepted but says the Portage browser
  profile isn't built yet (Phase 6) and behaves like `print`; `agent:<name>`
  passes the checkout URL and the same cart-summary payload
  `--notify-webhook` sends to a named agent the user has approved once in
  `~/.portage/config.json`'s new `handoff_agents` (a `command` argv run
  with a scrubbed environment, stdin JSON and a 30s timeout — never a
  shell string — or an `https` `webhook`), never invoked unless
  `"approved": true`. Every hand-off report's `handoff` object now also
  carries `handoff_target`, plus `agent_delivered`/`agent_error` for an
  `agent:<name>` target. New `Portage::Cli::HandoffTarget`, `HandoffAgents`
  (`lib/portage/cli/handoff_{target,agents}.rb`), and `Buy#handoff_notify_payload`
  now also carries `items:`.
  New `Portage::Cli::HandoffOnly` (`lib/portage/cli/handoff_only.rb`) is
  the one place Tier C's host list lives — every Amazon marketplace by
  default, fully replaced by `~/.portage/config.json`'s
  `"handoff_only_hosts"` once that key is present. `portage buy` against
  one of these hosts returns outcome `handoff_only` **before any request
  to that host** — no UCP probe, no homepage fetch, no cart — with a
  `checkout_url` (a product page/cart-add URL when a product id is known,
  the retailer's own search URL for the query when it's Amazon, or the
  origin's homepage otherwise, always built and never fetched) and a
  `legal_notice` (facts plus the as-is/no-warranty line). `portage find`
  and `portage index build`/`add`/`refresh` never probe a hand-off-only
  origin either — `find` still lists it as a candidate, marked
  `handoff_only: true`. `portage browser import`'s existing
  `handoff_only_hosts:` seam is now wired to the real list. `portage
  compare` and `PaymentMethods#enroll` (`portage payment enroll`) also
  refuse a hand-off-only origin before ever probing it (`compare` reports
  it hand-off only with the legal notice; enrollment reports
  `status: "handoff_only"` — "there's nothing to set up here"), and
  `HandoffReconciler#reconnect` refuses one too, as defense in depth (Buy's
  `handoff_only` outcome never reserves a pending record in the first
  place, so this path shouldn't be reachable, but it's the one place every
  reconcile fetches a store again from a saved record). `HandoffOnly#hosts`
  normalizes each configured entry — `"www.example.com"`,
  `"example.com/path"`, and `"https://www.example.com/s?k=x"` all reduce
  to `"example.com"` — the same normalization `BrowserImport::Importer`
  already applies to a history/bookmark domain. `portage
  doctor` gains a `handoff` finding (current target, the hand-off-only
  list, the disclaimer), and `portage setup`'s Hand-off step now also sets
  the target, approves a named agent, and edits the hand-off-only list.
  **Review caught three more real bugs before this shipped, all fixed:**
  (1) `HandoffAgents::Command`'s timeout never actually killed the child —
  `Open3.popen3`'s block form joins `wait_thr` in its own `ensure` once the
  block returns, so a `Timeout.timeout` firing inside it just meant popen3
  itself then hung waiting for the still-running child; fixed to
  `SIGTERM`, then `SIGKILL` after a short grace, and to actually wait for
  the child to die before leaving the block, plus draining stdout/stderr
  on their own threads (same as `Open3.capture3`) so a child that fills
  the stderr pipe can't deadlock a sequential read of stdout first. (2)
  `Index::Builder#reverify_stale` skipped by an entry's *stored*
  `handoff_only` flag rather than the live config, which was wrong in
  both directions — an origin whose UCP probe simply failed (stored
  `handoff_only: true`, but not a Tier C host) would never be re-verified
  again, and a stale entry recorded before the user added its host to
  `handoff_only_hosts` (stored `handoff_only: false`) would keep being
  probed; fixed to check `handoff_only_origin?` against live config
  instead, flipping a now-hand-off-only entry's stored flag with no
  request when it disagrees. (3) `Compare#resolve_origin` and
  `PaymentMethods#discover_session` still probed whatever origin/store URL
  they were given, including a hand-off-only one (`portage compare
  <amazon-url>` and `portage payment enroll <amazon-url>` both reached
  Amazon) — fixed as described above.
  `portage-cli`: 783 → 865 examples (+82: +70 from the phase's first pass,
  +12 from the review round above — a real-subprocess kill-on-timeout
  spec for `HandoffAgents::Command`, `Index::Builder#refresh` specs for
  both reverify-skip directions plus a `--dry-run` one, and one
  zero-requests spec each for `Compare`, `PaymentMethods#enroll`,
  `HandoffReconciler#reconnect`, and `HandoffOnly#hosts` normalization),
  0 failures; `rubocop` clean, no new cop disables.

- **`portage setup` — interactive setup wizard** (`docs/plans/
  buy-skill-and-local-browser.md` Phase 4). On a TTY, `portage setup` (and
  `portage doctor`/`configure` when `Doctor#nothing_configured?` — no
  `.env` file loaded, no shipping address, no policy at all) now walks
  through seven skippable steps: shipping address, search API keys, the
  agent profile, browser import, the local store index, spending policy
  caps, and hand-off. Under `--json` or with no TTY on stdin, every one of
  `doctor`/`configure`/`setup` stays exactly today's read-only report —
  proven by spec, not just described. New `Portage::Cli::SetupWizard` (`lib/
  portage/cli/setup_wizard.rb` + `setup_wizard/prompt.rb` +
  `setup_wizard/steps/{shipping,search_keys,agent_profile,browser_import,
  index_build,policy,handoff}.rb`). Each step delegates to the real command
  it configures — `portage generate agent-profile`, `portage browser
  import` (with its own confirm-before-save prompt intact), `portage index
  build`, `portage policy set` — rather than reimplementing any of them, so
  the wizard has nothing UCP- or network-specific of its own to get wrong.
  `Portage::Cli::DotEnv` gains `.update!`, the wizard's only writer to
  `~/.portage/.env`: updates a key in place (never duplicating it on a
  re-run), keeps every other line and comment untouched, creates
  `~/.portage` if needed, and is mode 0600 from the very first byte —
  a brand-new file is created with that mode already set (`File.open`,
  not `File.write` then `File.chmod`, which would briefly leave it at the
  process umask's default), and an existing file is chmod'd 600 *before*
  anything is written into it. Every secret prompt (Brave/Google CSE API
  keys) reads via `IO#noecho` on a real terminal and never echoes the
  value back, even in the wizard's own summary; Enter on any question
  keeps whatever's already set rather than clearing it, so re-running the
  wizard is always safe. `Steps::Policy` rejects a non-numeric or
  non-positive spending cap ("abc", "12x", "0") rather than silently
  coercing it to a 0 cap via `String#to_f`, and reuses
  `Portage::Cli.to_minor_units` (private, via `send`) for the major-to-
  minor-units conversion instead of a second implementation. The hand-off
  step configures the one hand-off setting that exists today
  (`CheckoutHandoff`'s auto-open toggle) and explains that a fuller choice
  of hand-off targets and the hand-off-only host list are Phase 5, not
  invented here — a deliberately easy seam for that phase to extend rather
  than a guess at its shape. `portage-cli`: 727 → 783 examples (+56), 0
  failures; `rubocop` clean, no new cop disables.
- **`portage browser import` — bookmarks and history as index seeds**
  (`docs/plans/buy-skill-and-local-browser.md` Phase 3, Tier A).
  `portage browser import [--browser chrome|edge|brave|arc|firefox|safari]
  [--profile-root DIR] [--history-days 90] [--include-product-pages]
  [--max-probes 200] [--exclude HOST,...] [--dry-run] [--yes] [--json]`
  (new `Portage::Cli::BrowserImport`). Reads only a profile's history and
  bookmark files — Chromium `History`/`Bookmarks`, Firefox
  `places.sqlite`, Safari `History.db`/`Bookmarks.plist`
  (`BrowserImport::Profiles::ALLOWED_FILES`) — and never a password,
  cookie or autofill store; a spec wraps every Ruby file/dir/subprocess
  entry point and fails if anything else in a fixture profile full of
  `Login Data`/`Cookies`/`Web Data`/`logins.json`/`key4.db`/
  `cookies.sqlite`/`formhistory.sqlite` decoys is touched. SQLite
  databases are copied (with their `-wal`) into a private tmpdir and
  queried with the system `sqlite3` CLI in `-readonly -json` mode, then
  deleted; Safari's binary plist goes through macOS's own `plutil` and a
  small XML-plist reader — no new gem dependency. Rows are reduced to
  domains, and obvious non-shops (`SearchBackends::NON_STORE_HOSTS`,
  webmail, banks/payment hosts, localhost/intranet/IP hosts, common
  tools and social sites) are skipped locally, as are domains already in
  the local index or the known-stores list. At most `--max-probes`
  (default 200) unknown domains, most-visited first, each get one
  `GET /.well-known/ucp` through `Portage::Ucp::Client.discover` and
  `ProbeCache` (5s timeout) — nothing else about the history is sent
  anywhere. A domain is kept when it answers, matches a WebMCP preset
  (skipped with no bridge), or is on the hand-off-only list (an
  injectable `handoff_only_hosts:` seam, empty until Phase 5). Each kept
  domain is classified from the user's own page titles, bookmark folder
  names and URL slugs, weighted by visit count; a domain that matches no
  category stays uncategorised. The list (with category names) is shown
  first and saved only after a "y" at a TTY prompt or an explicit
  `--yes` — under `--json` or with no TTY and no `--yes`, nothing is
  written and the report says `needs_confirmation: true`. Safari without
  Full Disk Access (and any other permission error) is explained and the
  command stops; it never works around it. Kept domains are written to
  `~/.portage/index/stores.json` with `sources: ["history"]`/
  `["bookmark"]`; `--include-product-pages` also writes product-page
  titles to `products.json` with the same labels.
- **`SearchBackends::Index` routes a store the query names** (its host, or
  its bare name as a whole word), after product matches and ahead of
  category matches — the only route an uncategorised browser-imported
  domain gets. Imported entries are otherwise ordinary untrusted index
  entries: `source: "index"`, never `merchant_allowlist`, never past the
  `--store`/interactive-pick gate for `--yes`.
- **`Index::Exporter` treats `history`/`bookmark` as personal** (alongside
  `browser`): a store found only that way is never exported, the labels
  are stripped from mixed-source entries, and a product whose only
  `sources` are personal (a `--include-product-pages` entry) is dropped
  even at a store a real source also found. `Index::ProductStore` entries
  now carry a `sources` list (the union of every sighting's), and
  `index build` records its own source on each product.
- **`Index::Sources::Browser` is now a pointer, not a reader.** It yields
  nothing, isn't a default `index build` source any more, and its
  `portage index sources` description points at `portage browser import`
  — `index build` never reads a browser on its own, since that would skip
  the import's approval step. The Phase 2b `browser-import.json` hand-off
  file is gone.
- `Classifier.names_for(ids)` (category names for display) and
  `Index::Builder.capabilities_of(session)` are now public, for the
  import to reuse.

- **`portage-cli/known-stores/{stores,products}.json` — a repo-committed,
  jsdelivr-hosted list every install fetches on top of its own local index**
  (`docs/plans/buy-skill-and-local-browser.md` Phase 2c). Same schema as
  `~/.portage/index/{stores,products}.json` (Phase 2b), published over the
  same `@main` jsdelivr channel `AgentProfileUrl` already uses
  (`Portage::Cli::KnownStoresUrl`), and cached at
  `~/.portage/index/known-{stores,products}.json`
  (`Portage::Cli::Index::KnownCache`). Fetched lazily the first time
  `SearchBackends::Index` needs it and no cache exists yet, refreshed
  unconditionally by `portage index refresh`, and refreshed by `doctor`
  whenever it finds the cache older than 7 days — every fetch is a single
  short-timeout GET per file, swallowed on any failure (offline, timeout,
  bad JSON, a non-2xx response) exactly like `SearchBackends`/
  `OfferSources::ShopifyCatalog`, so a missing or stale cache just means
  `find` works the way it did before this phase. A fetched entry is
  validated (must parse as a Hash of Hashes) and stripped of any
  `price`/`amount`/`stock` field before it's cached. `SearchBackends::Index`
  now merges this cache *underneath* the user's own
  `Index::Store`/`Index::ProductStore` entries — a known entry only shows
  up when the user's own index doesn't already have that origin/key, so a
  local `index add`/`index build` finding always wins — and is now
  `available?` from the known cache alone, with no local index at all.
  Still the same untrusted posture either way: an offer built from either
  source carries `source: "index"`, never a `merchant_allowlist`/`--yes`
  shortcut.
- **`portage index build`/`refresh --export DIR`** writes a PR-ready copy
  of your own local index into `DIR/{stores,products}.json` — the same
  shape as `known-stores/` in the repo, so publishing a new entry is
  "run this, `git add`, open a PR." A new `Index::Exporter` drops any store
  entry whose only `sources` is `"browser"` (history/bookmark-derived —
  Phase 3) outright, strips `"browser"` out of the `sources` of any entry
  that also has a real source, and keeps a product only if at least one of
  its `stores[].origin` survived that same filter (trimming its `stores`
  array down to just those origins) — nothing personal ships in an export.
- **`rake agent_profile:purge` is now an alias for `rake
  jsdelivr:purge[agent_profile]`.** The new `jsdelivr:purge` task (root
  `Rakefile`) covers every file this repo publishes over jsdelivr's
  `@main` channel by short name — `agent_profile`, `known_stores`,
  `known_products` — and purges all of them when called with no argument.
- Seeded `known-stores/{stores,products}.json` with a real
  `portage index build --sources shopify_catalog --export known-stores`
  run: 221 stores, 396 products, all `source: "shopify_catalog"`.
- **`portage index` — a local store and product index you build yourself**
  (`docs/plans/buy-skill-and-local-browser.md` Phase 2b). New commands:
  `portage index build [--sources a,b] [--queries FILE] [--dry-run]`,
  `index refresh` (re-verifies entries older than 7 days, then builds
  fresh), `index show [--stores|--products] [--json]`, `index add URL`,
  `index remove HOST`, `index sources`. Storage is
  `~/.portage/index/stores.json` and `products.json` — **never checked
  into git, never prices or stock** (those stay live), and `doctor` reports
  whether each file exists and how old its oldest verified entry is. One
  small source file each under `lib/portage/cli/index/sources/`:
  `shopify_catalog` (reuses `OfferSources::ShopifyCatalog` rather than
  duplicating its catalog-search/variant-URL logic; one query per
  top-level taxonomy node by default — 21 nodes, its own keyword rather
  than its full taxon name — or `--queries FILE`; not fanned out
  per-country, since `BuyerContext.from_env` already applies whatever
  locale the user has set), `stores_file` (the user's own `stores.yml`,
  via a new public `Allowlist#stores` reader), `browser` (reads Phase 3's
  eventual output file if present, yields nothing otherwise — Phase 3
  doesn't exist yet), `wikidata` (SPARQL for retail chains' official
  sites, CC0 — off by default, opt in with `--sources wikidata`: a live,
  read-only trial run returned real hits, but most skew toward chains with
  no UCP/WebMCP support at all), `webmcp_sweep` (needs a browser bridge
  that doesn't exist yet — skips cleanly). Every new origin gets one
  `/.well-known/ucp` probe through the existing `ProbeCache`, throttled,
  with progress output, capped at 500 per run. A new
  `SearchBackends::Index` applies Phase 2a's per-category/total routing
  caps to index entries, ranking a category's own matches by its weight
  (highest first), and additionally matches a query against a product by
  name or GTIN — whole-word, on the same `Classifier.tokenize`/
  `.word_match?` the category router itself uses (now public), never a
  substring — putting that product's own stores first; ranked between
  `Allowlist` and the web-search backends in `SearchBackends.default`. The
  index is untrusted data: it never writes
  `Portage::Ucp::Policy#merchant_allowlist`, and an index-sourced offer
  never lets `--yes` alone complete a buy — the same interactive-pick gate
  a web-search offer already gets.
- **`Classifier` and `known-stores/categories.yml`: a shared category
  taxonomy for `find` routing** (`docs/plans/buy-skill-and-local-browser.md`
  Phase 2a). `known-stores/categories.yml` ships in the gem — the top two
  levels of Google's published product taxonomy (213 nodes, keyed by
  Google's own numeric ids, each with a handful of plain keywords, the
  node's own taxonomy words) — and `~/.portage/categories.yml` overrides a
  shipped node (same id) or extends the taxonomy (a new id).
  `Portage::Cli::Classifier.categories_for(text)` takes a query, a product
  title/description, or a store/product URL (extracting the slug from
  `/products/`, `/collections/`, `/c/` or `/category/` and splitting
  `-`/`_` into words) and returns category ids ranked by keyword hits — no
  LLM, no network, so it works offline on a fresh gem/brew install. One
  classifier for queries, catalog products, stores.yml and (later) browser
  imports. Matching is whole-word, plus simple plural normalization
  (`Classifier.word_match?`: an exact match, a trailing `s`/`es`, or the
  `y`/`ies` swap — "boot"/"boots", "battery"/"batteries") — deliberately
  not a substring check, since a substring match goes both ways regardless
  of word boundaries ("carpet" contains "pet", "chair" contains "hair",
  "scarf" contains "car", "hot sauce" would have hit "photography") and an
  early classifier-spec run caught exactly that class of false positive
  before this shipped.
- **`stores.yml` entries may now carry `categories:`, and `find` routes by
  them instead of crowding out other candidates.** The file stays a bare
  URL list by default; an entry becomes `{url:, categories: [...]}` only
  once you tag it, and `PORTAGE_STORES` is unaffected either way.
  `SearchBackends::Allowlist#search` now classifies the query, puts any
  entry the query names outright first (its host or bare name appears in
  the query text, tagged or not), then adds up to 3 tagged stores per
  matching category not already named, capped at 12 in total
  (`Allowlist::PER_CATEGORY_CAP`/`TOTAL_CAP`, mirroring `Find::MAX_PROBES`).
  When no tagged store matches any of the query's categories at all, it
  falls back to named entries plus every *untagged* entry — never a
  tagged-but-unrelated one — so a `stores.yml` with no tags at all behaves
  exactly as it did before this change. Once at least one tagged store
  matches, though, nothing falls back to "every store": that's the
  crowding a heavily-populated `stores.yml` used to cause on every single
  query. Trust is unaffected — every allowlist entry is still always a
  candidate to `find`; this only changes which of them spend this query's
  probe slots, and in which order.
- **`find` gains a second backend kind: `OfferSource`, and a first
  implementation, `OfferSources::ShopifyCatalog`**
  (`docs/plans/buy-skill-and-local-browser.md` Phase 1). Unlike the
  URL-returning `SearchBackends`, an `OfferSource#offers(query, limit:,
  context:)` answers offers directly — no `/.well-known/ucp` probe, and it
  counts toward nothing in `Find::MAX_PROBES`. `Find#call` merges its
  offers with the probed ones before `Decisions.rank`. `ShopifyCatalog`
  calls Shopify's global catalog (`catalog.shopify.com/api/ucp/mcp`)
  anonymously and turns every result into an offer on the *merchant's* own
  origin: a catalog product's own id is a global one no merchant
  recognises, but each `variants[].id` is the merchant's real
  `ProductVariant` gid and `variants[].url` sits on the merchant's own
  domain, so the offer's `store`/`product_id`/`url` come from the first
  variant, not the product (live-verified 2026-09-28, query "hiking
  boots", GB/GBP — the four distinct merchant origins in the top 10 all
  answered `/.well-known/ucp`). `Buy#select_product` now also matches a
  product by one of its variant ids, and `#line_item_id_of` checks that
  exact variant out, so a `find`-picked catalog offer buys correctly with
  no title re-search. 5s timeout; any failure (network, timeout, a
  malformed result) is swallowed the same way a broken `SearchBackends`
  backend already is.
- **`PORTAGE_AGENT_PROFILE` now defaults to the repo's own published
  profile** (`Portage::Cli::AgentProfileUrl::DEFAULT`, the same jsdelivr
  URL `docs/agent-profile.md` already documents) when the env var is unset
  or blank, instead of `find`/`buy` failing outright on a fresh install
  that never copied `.env.example`. `portage doctor` reports which profile
  is in use — the env var's value, or that it's falling back to the
  default.
- **Fixed: `dry_run: true` was ignored on the WebMCP hand-off path**
  (docs/design-log.md §51). `Buy#webmcp_handoff_checkout_flow` still added
  to the store's real cart, sent the bridge's tab to checkout and ran
  autofill. It now stops after the read-only search and returns a
  `dry_run` report with a `would:` key (line item, hand-off tool, whether
  autofill would run). No cart, no hand-off, no prompt, nothing typed.
- **Docs for Phases 1-3** (docs/plans/webmcp-universal-outbound.md Phase 4,
  no code change): the README's "WebMCP (library use, opt-in)" section now
  covers the schema-matched/confirmed fallback for a page no preset
  recognizes, and `--autofill`/`PORTAGE_WEBMCP_AUTOFILL=approve`/
  config.json's `webmcp_autofill` — what it will and won't touch, and where
  it stops (`autofill_needs_headed_browser`, `autofill_blocked`).
- **Approved autofill of the store's checkout**
  (docs/plans/webmcp-universal-outbound.md Phase 3). Opt-in, per run:
  `--autofill`, or `PORTAGE_WEBMCP_AUTOFILL=approve` / config.json's
  `"webmcp_autofill": "approve"` (`Portage::Cli::WebmcpAutofillMode`) — off
  by default, and a generic truthy value like `"true"` doesn't turn it on,
  only the literal `"approve"`. Even opted in, nothing is typed until the
  shopper approves the exact field/value pairs in a new prompt
  (`Portage::Cli::WebmcpAutofillConfirm`) — refused outright with no prompt
  at all under `--json` or with no TTY, same posture as Phase 2's
  `WebmcpMappingConfirm`. Fields are contact email
  (`PORTAGE_SHIP_EMAIL`, new) and the shipping address `Portage::Cli::
  ShippingProfile` already reads from `PORTAGE_SHIP_*`, mapped onto WHATWG
  autocomplete tokens by the new `Portage::Cli::WebmcpAutofillFields`.
  `Buy#webmcp_handoff_checkout_flow` runs this once the bridge's browser has
  navigated to the store's own checkout (right after the hand-off tool
  call), via `portage-ucp-webmcp`'s new `WebMcp::Autofill` — never a payment
  field, never the pay button, and the run still always ends in
  `express_stop`, unchanged. A headless bridge (or one that never says)
  reports `autofill_needs_headed_browser`; a CAPTCHA/challenge on the page
  reports `autofill_blocked`; either way nothing is touched. The report
  gets a new `autofill:` key only when an attempt was actually made — a run
  with the mode off, or nothing configured to fill, looks exactly like it
  did before Phase 3 existed. `Buy.new` gained `autofill:` (the
  `--autofill` flag's value) and `webmcp_autofill_confirm:` (injectable, for
  specs). Live checks (does autofill actually reach a real Shopify checkout
  page's fields; is the cheapest-rate heuristic right against a real rate
  picker) are pending — no browser or live storefront available this
  session; noted in the plan's Progress log.
- Fix: `Buy#webmcp_flow` never ran against a real page. The Session
  `WebMcp.connect` returned had `nil` capabilities, so the cart/checkout
  check always fell through to adapter detection. Fixed in
  `portage-ucp-webmcp` (capabilities now come from the page's tools); the
  new `buy_spec` case goes through the real `connect`.
- `Buy#webmcp_flow` (docs/plans/webmcp-universal-outbound.md Phase 1) now
  detects a known WebMCP platform from the page's own tools
  (`portage-ucp-webmcp`'s new `Presets`) and, for a page whose tools are
  hand-off-only for checkout (Shopify's `proceed_to_checkout` is the first
  such preset — it navigates the browser rather than returning data),
  builds a cart, calls the hand-off tool, and reads the checkout URL off
  its result or, failing that, the tab's own `location.href` — then hands
  off exactly like any other WebMCP checkout.
- **Schema matching for a page `Presets.detect` doesn't recognize**
  (docs/plans/webmcp-universal-outbound.md Phase 2). `Buy#webmcp_flow`
  falls back to `portage-ucp-webmcp`'s new `Matcher.propose` when a plain
  connect (no preset, no `tool_names:`) doesn't advertise cart/checkout — a
  page that already speaks a preset's names or the bare UCP action names
  never reaches it at all. Read actions (`search_catalog`, `get_product`,
  `get_cart`) are used straight off the proposal; a mutating action
  (`create_cart`, `update_cart`, `create_checkout`) needs confirmation
  first: `Portage::Cli::WebmcpMappingConfirm` prints the proposed mapping —
  quoting each mutating tool's own `description` as untrusted page content,
  never as an instruction — and prompts on a real TTY with `--json` off;
  otherwise the run stops with outcome `webmcp_mapping_unconfirmed` and
  hands back the full proposal (`tool_names_proposal`) for the caller to
  resubmit as `tool_names:` on its own `WebMcp.connect` call. A confirmed
  mapping is stored in `~/.portage/webmcp_mappings.json`
  (`Portage::Cli::WebmcpMappings`), keyed by the page's tool fingerprint
  (`WebMcp::Fingerprint.for` — sorted tool names plus a hash of each input
  schema) rather than by origin, so it's shared across every store whose
  WebMCP tools have the exact same shape (decision 3) — in effect a local
  preset once confirmed once. `Buy.new` takes three new optional keywords:
  `webmcp_mappings:`, `webmcp_mapping_confirm:` (both injectable for specs)
  and `json:` (now threaded from `portage buy --json`, which no longer
  strips it before building `Buy` — Phase 2's confirm gate needs to know).

## [0.7.5] - 2026-09-25

- **`portage` loads `~/.portage/.env` on startup** (`Portage::Cli::DotEnv`),
  so the shipping address, search keys and adapter credentials can live in
  one file instead of a shell profile. `portage-console` does too. The
  real environment always wins, empty values are skipped, and
  `PORTAGE_ENV_FILE` names a different file. A `./.env` in the working
  directory is never loaded automatically, so running `portage` inside a
  cloned repo can't pick up that repo's proxy, webhook or credential
  settings. Stdlib only, so the Homebrew formula gains no resource.
  `portage doctor` reports the loaded file (`env_file`) and warns when
  other users can read it.
- **`portage doctor` runs the seller-side checks only for a seller.** The
  authenticator, rate limiter, signing keys and payment handlers checks
  inspect `Portage::Ucp.configuration`, which in a bare `portage` process
  is always the unconfigured default. So every fresh install got four
  warnings that meant nothing to a shopper and made doctor exit 1. They
  now run only with `--require` or `--adapter`; otherwise one info line
  says they were skipped. `Doctor.new` keeps running them by default
  (`seller: true`) for library callers.

## [0.7.4] - 2026-09-25

- **`portage doctor` reports how it was installed, and warns when another
  `portage` shadows it** (`docs/plans/homebrew-distribution.md` Phase 4).
  New findings, all offline and without shelling out to `brew`:
  - `install`: `homebrew` (with the Cellar keg) when this gem or its Ruby
    lives under `HOMEBREW_PREFIX/Cellar/portage/` (`$HOMEBREW_PREFIX`,
    then `/opt/homebrew`, `/usr/local`, `/home/linuxbrew/.linuxbrew`),
    otherwise `gem` with the gem's own path;
  - `runtime`: the Ruby version and `RbConfig.ruby` path, plus the
    `portage-cli` version;
  - `adapters`: each first-party adapter gem (plus `webmcp` and
    `decision`), whether it loads and at which version. A gem install
    without adapters is normal; a Homebrew install missing one is a
    warning, since the formula bundles them all. A broken adapter is
    reported, never raised;
  - `path`: every `portage` on `PATH`, compared by resolved Cellar
    location rather than raw path. Warns when a Homebrew install is
    shadowed by an earlier `portage` (typically a `gem install` copy in a
    mise/rbenv/asdf/rvm Ruby), naming the winner and how to fix it, and
    when a gem install is shadowed by a Homebrew one.
- `portage doctor` also warns when the `PORTAGE_SHIP_*` address is missing
  or incomplete, naming the missing variables. Without
  `PORTAGE_SHIP_COUNTRY` a native UCP store gets no buyer context, which
  is how a live Shopify store ended up reporting in-stock items as out of
  stock.
- `doctor` findings now carry a `level` (`warning` or `info`) and, for the
  new checks, structured `details`, both in `--json`. The JSON is still a
  top-level array. Only warnings make doctor exit 1; the text output lists
  info findings first, then the warnings or `No issues found.`.
- `ShippingProfile` treats an empty `PORTAGE_SHIP_*` value as unset, the
  way `BuyerContext` and the WooCommerce billing fallback already did, so
  a `.env` copied from `.env.example` with blanks left in no longer
  submits an address of empty strings.

## [0.7.3] - 2026-09-25

- **Proxy support** (`docs/plans/proxy-support.md` Phases 2-3). Every
  network command (`buy`, `find`, `compare`, `doctor`, `payment enroll`)
  takes `--proxy`, `--proxy-mode`, `--proxy-header`, `--no-proxy`,
  `--proxy-route`, `--proxy-chain`, `--proxy-passthrough`, `--proxy-ca` and
  `--no-env-proxy`, resolved per field against `PORTAGE_PROXY*` env vars
  and `~/.portage/config.json`'s `proxy` section into core's
  `Support::ProxyConfig`. `proxy.password_ref` resolves through Keychain or
  Secret Service (service `portage-cli-proxy`). The payment route stays
  direct unless a proxy is named for it explicitly, so payment traffic no
  longer inherits a bare `$http_proxy`/`$https_proxy`. `portage doctor`
  probes each configured proxy through `Support::Connection` and warns on
  plaintext credentials in `config.json`.
- Requires `portage-ucp` `~> 0.10` (for `Support::Connection` and
  `ProxyConfig`) and `portage-ucp-client` `>= 0.6.3` (for
  `Client::USER_AGENT`, which the default User-Agent is built from). Both
  floors were too low before: against `portage-ucp` 0.9.0 or
  `portage-ucp-client` 0.6.2, `require "portage/cli"` raised `NameError`.
- `portage --version` (also `-v` and `portage version`) prints the gem's
  version and exits 0. Needed so a packaged install — the Homebrew
  formula's offline `test do` block, or anyone else scripting around a
  release — can confirm which build is on `PATH` without hitting the
  network.
- **`portage-console` failed to start on Ruby 4.0.** It requires `irb`,
  which stopped being a default gem in Ruby 4.0 (it's a bundled gem now),
  and the gemspec never declared it, so any isolated install
  (Homebrew's, or anything under Bundler) raised `LoadError: cannot load
  such file -- irb`. `irb` is now a runtime dependency.
- **Did the shopper finish the checkout? `portage orders reconcile`.**
  Every checkout `portage buy` hands to the shopper's own browser
  (`requires_escalation`, `permission_denied`, `no_payment_token`,
  `policy_blocked`, `low_confidence`, `checkout_mismatch`) now reserves a
  pending record in the transaction log (best-effort — a failed write is a
  report warning, never blocks the hand-off). `portage orders reconcile
  [--checkout ID] [--json]` re-fetches each pending checkout from the store
  and settles it: `complete` only on a store-reported `completed` status,
  `failed` on `canceled` or an unanswered expiry, otherwise stays pending.
  Never infers success from a vanished checkout or a plain timeout. Safe to
  run from cron/launchd. See `docs/plans/handoff-reconcile.md`.
- **`handoff_spend_mode`** (`PORTAGE_HANDOFF_SPEND_MODE`, config.json) —
  whether a reconciled shopper purchase counts toward the buyer's own spend
  cap/velocity limit. `block` (default): counts like any agent purchase.
  `warn`: recorded but excluded from cap math. `precheck`: `block`, plus a
  spend-cap check at hand-off time that suppresses auto-open (never the
  URL) when this checkout would already exceed the cap.
- Phase 0 of the plan above (a live signal check against a real store) was
  not run before this shipped — see `docs/design-log.md` §44.
- **`portage buy --wait [--wait-timeout DURATION|off]`.** After a hand-off,
  polls `HandoffReconciler` with backoff (2s → 30s, plus jitter) until the
  checkout settles or its deadline passes — the earlier of
  `handoff_wait_timeout` (`PORTAGE_HANDOFF_WAIT_TIMEOUT`, config.json;
  default 30m, `off` removes it) and the checkout's own `expires_at`.
  Ctrl-C or the deadline leaves the record pending for a later `portage
  orders reconcile`; it never settles from the wait itself. Under `--wait
  --json`, stdout streams NDJSON (`handoff`, `handoff_status` on each
  store-reported status change, `handoff_settled`) followed by the final
  report object; plain `--json` with no `--wait` is unchanged byte-for-byte.
- **`reconcile_notify`** (`PORTAGE_RECONCILE_NOTIFY`, config.json) — a comma
  list of channels a settled hand-off notifies on, from `--wait` or `portage
  orders reconcile`. Default `webhook`. Adds `macos` (a native notification,
  merchant/amount escaped into a fixed AppleScript template) and `terminal`
  (a printed line, forced on for a plain-text `--wait` regardless of
  configuration). `journal` is accepted for documentation — the Phase 1
  order-snapshot journal write was already unconditional.
- **WebMCP outbound, opt-in (Phase 4, partial).** `Buy.new(webmcp_bridge:)`
  takes a `portage-ucp-webmcp` outbound bridge already pointed at a
  navigated page; when given one, `portage-cli` tries it after native-UCP
  discovery finds nothing and before a platform-adapter fallback. Only
  `webmcp_checkout_mode: express_stop` (the default) is implemented: it
  builds the cart/checkout and always hands off (reason `express_stop`),
  feeding Phases 1-3 unchanged, since a WebMCP page doesn't expose
  `complete_checkout` by default anyway. `token` mode reports
  `webmcp_token_unsupported` rather than attempting completion — it still
  needs a `Confirmer`-swap seam in `Mcp::Server.build` and payment-token
  enrollment that don't exist yet. No new hard runtime dependency:
  `portage-ucp-webmcp` is lazily `require`d, same posture as an optional
  platform adapter gem.

## [0.7.2] - 2026-09-24

- The User-Agent every store-facing request sends (`Cli::UserAgent`, née
  `Cli::USER_AGENT`/`Cli::HTTP_HEADERS`) is now configurable: `PORTAGE_USER_AGENT`
  beats `~/.portage/config.json`'s `user_agent` key, both of which beat the
  `portage-cli/<ver> portage-ucp-client/<ver> (+https://github.com/...)`
  default — same precedence `Notifier`'s webhook URL already uses. `portage
  doctor` (and its `configure`/`setup` aliases) now flags a configured value
  containing a stray newline, since `Net::HTTP` would otherwise raise on it
  mid-checkout instead of at setup time.

## [0.7.1] - 2026-09-24

- Fix: `buy <url> --max-price` (and `--product-id` with `--max-price`) was
  silently ignored — `add_search_options` only wired `--max-price` into the
  `find` options, not `buy`, so a URL-driven buy could complete over the cap
  the caller set. `Buy#select_product` now filters to products within
  `max_price` first, using a variant's own price where available and
  otherwise the product's lowest price (unpriced products stay eligible,
  same rule `Find` already used). `no_match_message` now names the cap.
- Every store-facing request (`discover()` calls and the notifier webhook
  POST) now sends `portage-cli/<ver> portage-ucp-client/<ver>
  (+https://github.com/tomtom87/Portage)` instead of Ruby's or Faraday's
  default User-Agent. New `Cli::USER_AGENT`/`Cli::HTTP_HEADERS`
  (`lib/portage/cli/user_agent.rb`) replace the ad-hoc UA strings each of
  `portage-buy`, `portage-find` and `portage-payment-enroll` built on their
  own. Requires `portage-ucp-client >= 0.6.3`.

## [0.7.0] - 2026-09-23

- **The decision layer is wired in.** `buy`/`find` make their judgment
  calls through the same rules `portage-ucp-decision` wraps. Ranking,
  escalation and the policy check live in `portage-ucp` core
  (`Support::OfferRanking`, `Support::Escalation`, `PolicyGuard`), so they
  run the same with or without that gem. `portage-ucp-decision` stays an
  optional plugin that only the confidence gate needs. Every checkout
  report carries the verdicts under `decisions:` (`escalation`, `policy`,
  and `confidence` when enabled). Requires `portage-ucp ~> 0.9`.
  - `find` ranks offers buyable first, then cheapest, then unpriced. The
    order is unchanged.
  - When a checkout both requires escalation and mismatches the request
    under `PORTAGE_ABORT_ON_CHECKOUT_MISMATCH`, `buy` now reports the
    store's escalation, not the mismatch. Both hand off the checkout.
  - `buy --yes` now checks your spend policy before completing, on remote
    native-UCP stores too. Before, only the own-store flow's in-process
    `Dispatcher` enforced it, so a remote store never saw your caps,
    allowlist or token scopes. A blocked purchase hands off the checkout.
  - New opt-in confidence gate: `--decision-backend jev|laya` /
    `PORTAGE_DECISION_BACKEND`, with a threshold from `--min-confidence` /
    `PORTAGE_MIN_CONFIDENCE` (default `0.8`). Needs `portage-ucp-decision`.
    A low score, a backend that can't answer, or a missing gem holds the
    purchase and hands off the checkout.
  - Every verdict carries a `reason`: a string, or null when the gate
    passed, the same in-process as in `--json`. `confidence.reason` is
    `below_threshold`, `backend_error` or `not_installed`, and
    `confidence.error` holds the detail behind the last two.
- **`buy` checked out sold-out items when in-stock matches were right
  there.** It took the top search hit and its first variant unconditionally,
  so a sold-out top hit dead-ended on the store's "Sold out" refusal
  (allbirds.com and billabong.com, 2026-09-23). It now takes the first hit
  with stock, and that product's first in-stock variant. When nothing
  reports stock it still falls back to the top hit, and `--product-id`
  still buys exactly that product.
- `doctor` accepts `TYPESAFE_API_KEY` in place of `JEV_API_KEY`, matching
  `portage-ucp-decision`'s Jev backend.
- **An agent couldn't tell a held purchase from a bought one without reading
  prose.** `decisions:` only covers the three gates, so a missing payment
  token, a permission-denied store, a dry run or a missing `--yes` all
  showed `escalate: false, allowed: true`. Every `buy` report now carries
  `outcome` (`purchased`, `no_payment_token`, `policy_blocked`, ... — the
  full list is in the README), and the text output leads with it as
  `[outcome]`. Checkout reports also carry `items`, what the checkout
  actually holds, alongside `products`, the search results.
- **History recorded the wrong things.**
  - A purchase entry listed all ten search results, not what was bought,
    and had no way to tell a completed purchase from a dry run or a held
    one. Entries now carry `outcome`, `items`, `total`/`currency`,
    `checkout_id`, `source`, and the `checkout_url` for anything not
    completed.
  - A `buy` whose search matched nothing was logged as a purchase. It's now
    a search at that store, as are browse-only and dead-end buys, which
    weren't logged anywhere.
  - The search behind a `buy` with no URL wasn't logged at all.
- **Checkout hand-off webhooks.** The body now includes the report's
  `message`, the `store` and the shopper's `query`, so a Slack/Zapier relay
  can post it without a lookup. A plain-text 2xx (Slack's `ok`) was
  reported as a failed delivery, because the reply was parsed as JSON; any
  2xx now counts. The POST times out after 5s instead of stalling the buy
  for up to two minutes.
- **The confidence gate could crash a buy after the checkout existed.** Only
  `Decision::Error` was rescued, so a backend's timeout, parse error or
  missing binary escaped as a backtrace with no report, hand-off or history
  entry. Any failure now holds the purchase like a low score does.
- **The spend policy failed open on a checkout with no total.** PolicyGuard
  skips both caps without an amount, so `buy --yes` completed past a
  configured cap while reporting `allowed: true`. It's now denied as
  `total_unknown` whenever a cap is set.
- `doctor` checks the confidence backend you selected
  (`PORTAGE_DECISION_BACKEND`): the gem missing, an unknown name, a missing
  `JEV_API_KEY` or Laya bridge, or a bad `PORTAGE_MIN_CONFIDENCE`. It no
  longer asks for `JEV_API_KEY` when no backend is selected.
- The no-buyer-context warning names every variable it reads and says to
  set at least `PORTAGE_SHIP_COUNTRY`.
- **Settings resolve one way everywhere.** The auto-open toggle, the
  notify webhook, `PORTAGE_ABORT_ON_CHECKOUT_MISMATCH` and the confidence
  gate's backend/threshold each parsed their own env var and repeated the
  "flag, then env var, then `config.json`" order. They now share
  `Portage::Cli::Setting`. Two edge cases change:
  - A blank flag or env var (`PORTAGE_AUTO_OPEN_CHECKOUT=`,
    `--notify-webhook ""`) is unset and falls through to the next level.
    Before, an empty auto-open env var turned auto-open off, and an empty
    `--notify-webhook` turned the webhook off.
  - A `config.json` `"auto_open_checkout"` string is read like the env var,
    so `"no"` means off. Before, any non-empty value meant on.
- Report totals and the policy check's amount come from core's
  `Support::Totals.amount` instead of their own lookups.
- **Remote purchases didn't count toward the rolling cap or velocity
  limit.** Both count the transaction log (`~/.portage/transactions.json`),
  and only the own-store `Dispatcher` wrote to it, so `buy --yes` against a
  remote native-UCP store never added to either. `buy` now records a remote
  completion there under the merchant host, with its amount, currency and
  token ref: reserved before the store is asked, settled `complete` only
  when it comes back purchased, `failed` otherwise. The own-store loopback
  path is still left to `Dispatcher`, so nothing is counted twice. If the
  log can't be written after the purchase, the report says so in
  `warnings` rather than losing the purchase to an exception.
- **A garbage `PORTAGE_MIN_CONFIDENCE` broke every `buy`**, even with no
  decision backend selected, because the threshold was parsed up front
  either way. The env var is now read, and validated, only once a backend
  is selected. An explicit `--min-confidence` is still always validated.
- **`buy --json` could refuse a flag without any JSON.** An out-of-range
  threshold went to stderr as a bare line, and a flag OptionParser couldn't
  read (`--min-confidence high`, an unknown flag) escaped as a backtrace.
  Under `--json` both now print a report with `outcome: "invalid_option"`
  and exit 1; without it, both are one line on stderr. The threshold is
  also checked before the search when `buy` has no URL, not after it.

## [0.6.4] - 2026-09-22

- **Every dead-end hand-off pointed the shopper at the store's refund
  policy.** `#checkout_url_of` took the first entry in the checkout's
  `links` with a url, on the reasoning that not every backend types its
  link entries. Live UCP stores put nothing *but* policy links there:
  five third-party Shopify stores checked 2026-09-22 returned
  `refund_policy`, `privacy_policy`, `terms_of_service`, `shipping_policy`
  and `contact_information`, and never a checkout link — the checkout is
  always at `continue_url`. So `requires_escalation`, permission-denied and
  no-payment-token reports all handed over a policy page, `--auto-open`
  opened it and `--notify-webhook` posted it. Now reads `continue_url`
  first, and the `links` fallback skips policy/contact entries rather than
  handing over a wrong URL.
- `adapter_flow` rescued `LoadError` and `StandardError` identically,
  returning `nil` either way — correct once the adapter gem genuinely isn't
  installed, wrong once it's live and its own call actually failed. A live
  adapter's `StandardError` (e.g. "no payment_method configured on this
  Adapter") now comes back as its own report instead of the generic "no
  automated path" dead end, distinguishable from "no adapter for this
  platform" by `source`.

## [0.6.3] - 2026-09-22

- A store refusing a cart or checkout call on its own terms — out of stock,
  a line it won't take, an expired cart — is reported as a normal outcome
  carrying the store's own sentence and its `continue_url`, instead of
  escaping `Buy#call` as an unhandled `Client::ServerError`. It printed a
  Ruby backtrace whose "message" was the store's entire several-kilobyte
  `ucp` error envelope; confirmed live 2026-09-22 against a genuinely
  sold-out variant. Same posture `requires_escalation` and
  `PaymentPermissionError` already had.
- Requires `portage-ucp-client ~> 0.6` (was `~> 0.5`), which is what
  `Buy#complete`'s `rescue Client::PaymentPermissionError` has actually
  needed since 0.6.2 — that constant landed in client 0.6.0, and a `rescue`
  naming a missing constant raises `NameError` over the top of whatever
  error it was meant to catch.

## [0.6.2] - 2026-09-22

- `Buy#complete` treats a `Client::PaymentPermissionError` from
  `complete_checkout` (this agent not yet granted checkout-completion on the
  store) as a normal outcome rather than a failure — same posture as
  `requires_escalation`: the report carries the checkout's `continue_url`
  so the shopper can finish on the merchant's own checkout page.
- Every dead-end `buy` outcome that hands a shopper a `checkout_url`
  (`requires_escalation`, permission denied, no `--payment-token`) can now
  auto-open that link in the shopper's browser and/or POST it to a webhook,
  instead of leaving it as inert text/JSON. Both off by default; opt in with
  `--auto-open`/`--notify-webhook <url>`, `PORTAGE_AUTO_OPEN_CHECKOUT`/
  `PORTAGE_NOTIFY_WEBHOOK_URL`, or `~/.portage/config.json`
  (`auto_open_checkout`/`notify_webhook_url`), in that precedence order.
  Never fires on `--dry-run`. Best-effort throughout: a failed open or POST
  never fails the buy, and surfaces instead as `handoff: {opened:,
  notified:, notify_error:}` on the report. New `CheckoutHandoff`, `Notifier`,
  and `Config` classes; `portage-ucp` core is untouched.

## [0.6.1] - 2026-09-22

- `portage generate agent-profile` emits the capability identifiers a UCP
  server actually resolves an agent's tool registry from. It was emitting
  `dev.ucp.shopping.catalog` — reusing `Portage::Ucp::Capabilities::CATALOG
  .name`, which is correct for a business's own manifest, where one Capability
  owns all three catalog actions, and wrong here: the registry is per action
  (`dev.ucp.shopping.catalog.search`, `dev.ucp.shopping.catalog.lookup`). A
  profile declaring the coarse name resolved to zero catalog tools, and stores
  reported that as `-32602 Tool not found: search_catalog` seconds after
  `tools/list` advertised it. Versions are now spec revisions (`2026-08-25`)
  rather than `"1"`, and `ucp.services` declares the shopping service instead
  of being left `{}`. The checked-in
  `agent-profile/agent-profile.json` is regenerated, existing signing keys
  kept. See `docs/ucp-tool-gating-investigation.md`.
- New `Portage::Cli::BuyerContext` builds the UCP `context` object from
  `PORTAGE_SHIP_COUNTRY`/`PORTAGE_SHIP_REGION`/`PORTAGE_SHIP_POSTAL_CODE`,
  `PORTAGE_CURRENCY` and `PORTAGE_LANGUAGE`. `buy` and `find` send it on every
  catalog and checkout call — without it a real store builds an empty cart and
  calls it sold out. Partial by design, unlike `ShippingProfile`, which stays
  all-or-nothing because a half-filled address can't be submitted.

## [0.6.0] - 2026-09-17

- Fixed `buy`/`find` crashing with a raw `Faraday::UnprocessableContentError`
  against a real UCP store, once manifest parsing succeeded — the actual
  `search_catalog`/`create_checkout` calls were still built in the wrong
  wire shape (see `portage-ucp-client` 0.4.0). Both commands
  now report a clear, actionable message instead: set `PORTAGE_AGENT_PROFILE`
  when it's missing, or surface the store's rejection cleanly when it's set
  but not accepted.
- Added `PORTAGE_AGENT_PROFILE` — required for `find`/`buy` against a real,
  external UCP store (not your own store via an adapter). No default; see
  `.env.example`.
- Fixed `buy` sending a catalog product's own id as the purchasable line
  item — correct for a backend where "the product" and "the thing you add
  to a cart" share one id, but wrong for Shopify (confirmed live: every
  `portage buy` against a real Shopify test store failed with "Invalid id",
  since Storefront's cart takes a `ProductVariant` GID, not the parent
  `Product` GID `search_catalog` returns as `id`). `Buy#full_buy` and
  `#redirect_checkout` now build `line_items` from a product's first/
  default variant id when one exists, falling back to the product id
  otherwise; `--product-id` matching (`#product_id_of`) is unchanged, since
  it still needs to match the catalog-level id `find`/`compare` show the
  caller.
- Added `portage generate agent-profile`, which writes a real UCP
  agent-identity document (the JSON a store fetches from the
  `meta.ucp-agent.profile` URL to decide whether to answer at all).
  `portage-cli`'s own generated profile is checked in at
  `agent-profile/agent-profile.json` and published to a stable URL by
  `.github/workflows/publish-agent-profile.yml`, which is what
  `PORTAGE_AGENT_PROFILE` defaults to pointing at.
- Widens the `portage-ucp` pin to `~> 0.8` and the `portage-ucp-client` pin
  to `~> 0.4` so this gem installs alongside the 0.8.0-line releases.

## [0.5.1] - 2026-09-16

- No behavior change — 0.5.0 was built and pushed with `gem build` run from
  the workspace root instead of this gem's own directory, so `spec.files =
  Dir[...]` resolved against the wrong working directory and packaged an
  empty gem. 0.5.0 has been yanked; 0.5.1 repackages the exact same 0.5.0
  code correctly.

## [0.5.0] - 2026-09-16

- Added `portage-console` — a read-only IRB REPL over the local
  `TransactionLog`/`OrderLedger`/`PurchaseJournal` stores (design-log §22
  item 6, `Portage::Cli::Console`). `transactions`/`find_transaction`/
  `transactions_since`, `orders`/`find_order`, and `journal`. Every result
  passes through `Portage::Ucp::Observability.redact`. Deliberately a local
  REPL, not the admin/web panel design-log §16 also describes — see the
  README's Console section for why. New runtime dependency on
  `portage-ucp-journal` (`~> 0.1`).
- `Buy#client_for` now passes a real `Portage::Ucp::Journal::PurchaseJournal`
  (file-backed, `~/.portage/journal.jsonl`) into `Client.for_adapter` — the
  own-store loopback path used by `portage buy` against your own store now
  actually records to the purchase journal, closing the gap `portage-console`
  above depends on: `journal` was empty on this path because nothing passed
  `journal:` through it (design-log §37/§38).
- Added `portage generate adapter` — scaffolds a new adapter gem (gemspec,
  Gemfile, Rakefile, rubocop config, lib entrypoint, version file, an
  `Adapter` subclass with every capability method stubbed by reflecting off
  `Portage::Ucp::Adapter`'s real method signatures, and a conformance spec),
  modeled on `portage-ucp-etsy`.
- Added `portage doctor` — sanity-checks a seller's
  `Portage::Ucp.configuration` (authenticator/rate-limiter left at
  unconfigured fail-safe defaults, no signing keys/payment handlers
  configured, adapter capabilities only half-implemented).

## [0.4.1] - 2026-09-15

- No behavior change — widens the `portage-ucp` dependency pin to `~> 0.6`
  so this gem can install alongside `portage-ucp` 0.6.0 (the pessimistic
  `~> 0.5` pin published with 0.4.0 excludes it).

## [0.4.0] - 2026-09-14

- Added `portage payment list/enroll/set-default/remove/freeze/revoke` —
  card-on-file storage so `buy`'s `--payment-token` dead-end can fall back to
  a stored default (`@payment_token ||= PaymentMethods.default`) instead of
  requiring a fresh token on every call (docs/plans/agentic-payments.md
  Phase 1). Storage picks macOS Keychain / Linux Secret Service (`secret-tool`,
  D-Bus session required) / a headless `PORTAGE_PAYMENT_TOKEN`-only tier, in
  that order, with no homegrown fallback store. `enroll` is a browser handoff
  to a gateway-hosted setup page (the new `app.portage-ucp.payment_enrollment`
  capability in `portage-ucp`) — no raw card number ever reaches this
  process.
- Added `portage payment enroll --scope-merchant/--scope-max-amount/
  --scope-currency` — binds a Phase 2 per-token policy scope at enrollment
  time, written to `Portage::Ucp::Policy` keyed by the same `token_ref`
  `PolicyGuard` derives from the token at charge time.
- Added `portage policy show/set` — manages the Phase 2 policy file's
  top-level caps/velocity/allowlist (`Portage::Ucp::Policy`), checked by
  `PolicyGuard` on every `complete_checkout`.
- Widened the `portage-ucp` dependency pin from `~> 0.4` to `~> 0.5` and the
  `portage-ucp-client` pin from `~> 0.2` to `~> 0.3` — this release's
  `Policy`/`PolicyGuard`/`TokenRef` and `Session#create_payment_enrollment`
  calls only exist from those versions on.

## [0.3.0] - 2026-08-28

- Fixed: `find` and `buy` were treating `search_catalog`'s wire envelope
  (`{"ucp" => ..., "products" => [...]}`) as the product list itself —
  `Array(session.search_catalog(...))` wrapped the whole envelope Hash into a
  single-element array instead of unwrapping `"products"`, so every offer
  built from it was malformed against any real store. `Portage::Cli::CatalogProducts.from`
  now unwraps the envelope (and the own-store adapter's raw
  `CatalogSearchResult`) before either command touches the result.
- `portage compare <url> --product-id ID` (`Portage::Cli::Compare`, §22's
  "find this same item elsewhere" mode) — resolves a named product, then runs
  `find`'s own candidate-discovery/probe/rank pipeline against its title.
  Every offer carries a `match:` tier (`confirmed`/`likely`/`unconfirmed`)
  based on shared barcode/sku/`--id` identity, the origin store is excluded
  by host, and `--results` truncates after ranking. Catalog-price only — no
  `create_checkout` against candidate stores. Recorded to `portage history`
  as a search.
- `portage history` — local purchase/search history (`Portage::Cli::History`),
  logged automatically to `~/.portage/history.json` on every `find`/checkout-
  reaching `buy`. `list` (`--purchases`/`--searches`, `--limit`, `--json`) and
  `clear` (same scoping flags) subcommands. Separate from `ProbeCache`, which
  remembers hosts, not actions.

## [0.2.0] - 2026-08-21

- `PORTAGE_SHIP_*` env vars (`Portage::Cli::ShippingProfile`) — configure a
  default shipping address for `portage buy`'s own-store adapter-loopback
  path, the same way adapter credentials already live in env. `portage buy`
  auto-picks the cheapest priced option per fulfillment group once an address
  is submitted; there's no interactive rate picker, since the CLI drives one
  automated purchase rather than a conversation. The native UCP session path
  (a third-party store over stdio/HTTP) isn't wired yet — no real UCP server
  to verify a `fulfillment` wire shape against.

## [0.1.0] - 2026-08-14

- Initial pre-release. `portage buy <url>` — native UCP discovery first,
  adapter fallback only when this process already has that platform's own
  credentials.
- `portage find --query "..."` — find UCP stores that stock something without
  knowing a URL, via an allowlist, DuckDuckGo, Brave, or a Google Programmable
  Search engine, then probe each candidate for `/.well-known/ucp` and search
  the survivors' catalogs. Probe results are cached in
  `~/.portage/discovery-cache.json`.
- `portage buy` with no URL runs that search and buys the offer you pick.
  `--yes` alone won't buy from a search result: the merchant has to be named by
  `--store` or an interactive pick.
- `portage buy --product-id ID` buys exactly that product instead of whatever
  the catalog search ranks first.
