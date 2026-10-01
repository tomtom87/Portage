# portage-cli

Ships the `portage` executable — one CLI command to buy from any store, native
UCP or not.

```bash
portage buy https://your-shop.example --query "snowboard" --qty 1 --payment-token spt_1a2b3c...
```

`portage buy <url>`:

1. Tries native UCP discovery first (`GET /.well-known/ucp`, then a `<link
   rel="ucp">`-style tag on the homepage) — zero credentials, works on any
   store that's opted in.
2. Falls back to a `portage-ucp-<platform>` adapter **only** when this process
   already has that platform's own credentials in env — i.e. it's your own
   store, or one you're integrated with.
3. Otherwise says so plainly and stops — never scrapes or session-hijacks as an
   anonymous shopper. That fallback path is a ToS violation this gem
   deliberately refuses to take.

Don't have a URL? `portage find` asks a search backend which stores might sell
the thing, keeps the ones that answer `/.well-known/ucp`, and lists what they
actually stock:

```bash
portage find --query "burton snowboard" --max-price 400
```

`portage buy` with no URL runs that search and then buys the offer you pick.

Already know the store? `portage find --store URL --query "..."` skips the search
backends and offer sources and searches only that store's catalogue, live and
read-only (catalogue search only, never a cart or checkout). Use it to re-check
an index hit or an earlier offer before quoting its price or stock. The report
has the same shape as a normal find (`offer_ref`, `search_id`, a history entry),
so `pick` and `buy --offer` work on its offers. A hand-off-only host is never
fetched and is reported as such; a store that doesn't speak UCP is reported as
having no catalogue, with exit code 1 (as for any find with no offers). `--store`
must be an http(s) URL (a bare host is read as https).

```bash
portage find --store https://shop.example --query "cold brew" --json
```

Already have the item and want to know where else it's sold? `portage compare`
resolves a product you name by URL + product id, then runs the same
find pipeline against its title and ranks the results by how confident the
match is:

```bash
portage compare https://your-shop.example --product-id prod_123 --results 5
```

Depends on [`portage-ucp`](https://github.com/tomtom87/Portage/tree/main/portage-ucp)
(for platform detection via `Resolver`),
[`portage-ucp-client`](https://github.com/tomtom87/Portage/tree/main/portage-ucp-client)
(for the actual buy calls), and
[`portage-ucp-journal`](https://github.com/tomtom87/Portage/tree/main/portage-ucp-journal)
(for `portage-console`'s read-only view of local purchase state — see below).
No single adapter gem is a hard dependency — install whichever
`portage-ucp-<platform>` gem matches the store you're integrated with, if any.

## Installation

**Homebrew** (macOS and Linux) — recommended for using the CLI:

```bash
brew install tomtom87/portage/portage
```

The formula installs `portage-cli` plus every adapter gem (Shopify, Wix,
WooCommerce, BigCommerce, Magento, Etsy, Instagram, WebMCP, Decision) into
its own directory, running on Homebrew's own `ruby`, so it doesn't depend on
or change whichever Ruby you use for anything else. It gives you `portage`
and `portage-console`.

**RubyGems** — on any Ruby ≥ 3.2, or when you only want some adapters:

```bash
gem install portage-cli
gem install portage-ucp-shopify   # optional: add only the adapters you need
```

In an app's `Gemfile` instead:

```ruby
gem "portage-cli"
```

### Upgrading

- Homebrew: `brew upgrade portage`. Your config and data in `~/.portage`
  (policy, payment-method metadata, transaction log, order ledger,
  `config.json`) are left alone, as they are by `brew uninstall`.
- RubyGems: `gem update portage-cli` (and any adapter gems you added).

Portage has no self-update command, by design: whichever tool installed it
owns upgrades.

### Linux: stored secrets need `secret-tool`

On Linux, stored payment tokens (`portage payment enroll`) and proxy
passwords (`password_ref`) live in the Secret Service (GNOME Keyring,
KWallet) via the `secret-tool` command. It comes from your distribution,
not from the formula or the gem:

```bash
sudo apt install libsecret-tools   # Debian/Ubuntu
sudo dnf install libsecret         # Fedora
```

Without it (or without a live D-Bus session, e.g. over SSH or in CI),
Portage uses the headless tier: the token comes from
`PORTAGE_PAYMENT_TOKEN` and nothing is stored locally. On macOS the
Keychain is used and nothing extra is needed.

### Two copies on PATH

A `gem install` copy and a Homebrew copy can both be installed, and your
shell runs whichever `portage` comes first on `PATH`. A common case is an
old gem copy in a mise, rbenv, asdf or rvm Ruby's `bin`, which then keeps
running after `brew install` or `brew upgrade`. `portage doctor` warns
about this. To check:

```bash
which -a portage
```

To fix it, keep one copy: `gem uninstall portage-cli` (with the Ruby that
owns the gem copy active) to use Homebrew's, or `brew uninstall portage` to
use the gem's. Or reorder `PATH` so the one you want comes first.

## Usage

<!-- usage-start -->
```bash
portage buy <url> --query "..." [--qty N] [--payment-token TOKEN] [--product-id ID]
                                [--yes] [--dry-run] [--auto-open|--no-auto-open]
                                [--notify-webhook URL]
                                [--handoff-target default|print|profile|agent:NAME]
                                [--decision-backend jev|laya] [--min-confidence N] [--json]
                                [--wait [--wait-timeout DURATION|off]]
portage buy --offer REF [--qty N] [--yes] [--dry-run] ...
portage buy --quote QUOTE_ID --yes [--json] ...
portage buy --query "..." [--store URL] [--max-price N] [--limit N] ...
portage find --query "..." [--max-price N] [--limit N] [--json]
portage find --store URL --query "..." [--max-price N] [--json]
portage compare <url> --product-id ID [--id VALUE ...] [--results N]
                       [--max-price N] [--json]
portage check <url> [--json]
portage pick [--search LAST|SEARCH_ID] [--via auto|tty|agent] [--json]
             [--choose REF | --compare REF | --view REF]
portage approve QUOTE_ID [--via auto|tty|agent] [--relayed-yes | --view] [--json]
portage history [list] [--purchases|--searches] [--limit N] [--json]
portage history clear [--purchases|--searches]
portage payment list [--json]
portage payment enroll <url> [--label NAME] [--json]
                              [--scope-merchant HOST ...] [--scope-max-amount N] [--scope-currency CUR]
portage payment set-default <id>
portage payment remove <id>
portage payment freeze <id>
portage payment revoke <id>
portage policy show [--json]
portage policy set [--per-transaction-cap N --currency CUR]
                    [--rolling-cap N --rolling-window-seconds N --currency CUR]
                    [--velocity-count N --velocity-window-seconds N]
                    [--allow HOST ...] [--clear-allowlist]
                    [--require-approval person|any|off]  (lowering asks at a terminal)
portage orders reconcile [--checkout ID] [--json]
portage index build [--sources a,b] [--queries FILE] [--dry-run] [--export DIR] [--json]
portage index refresh [--sources a,b] [--queries FILE] [--dry-run] [--export DIR] [--json]
portage index show [--stores|--products [--page N] [--per-page N]] [--json]
portage index search QUERY [--category ID] [--store HOST] [--limit N] [--json]
portage index add <url> [--crawl] [--json]
portage index remove <host> [--json]
portage index sources [--json]
portage browser import [--browser chrome|edge|brave|arc|firefox|safari] [--profile-root DIR]
                       [--history-days 90] [--include-product-pages] [--max-probes 200]
                       [--exclude HOST,HOST] [--dry-run] [--yes] [--json]
portage browser profile init|open|status [--browser chrome|edge|brave|arc] [--port N]
                       [--url URL (open only)] [--json]
portage doctor [--require FILE] [--adapter CLASS_NAME] [--json]   # alias: configure
portage setup [--json]   # interactive wizard on a TTY; --json/no TTY: today's doctor report
portage generate adapter NAME [--dir DIR]
portage generate agent-profile [--out FILE] [--key-out FILE] [--rotate]
portage --version
```
<!-- usage-end -->

`buy`/`find`/`compare`/`doctor`/`payment enroll` (the network-touching commands —
`orders reconcile` doesn't take these) also accept:

```
[--proxy URL] [--proxy-mode forward|gateway] [--proxy-header "Name: value"]
[--no-proxy HOSTS] [--proxy-route ROUTE=URL|direct] [--proxy-chain URL,URL,...]
[--proxy-passthrough HEADER] [--proxy-ca FILE] [--no-env-proxy]
```

See "Proxy" below.

- `--query` — search term. Against the store's catalog when you name a store,
  against the search backends when you don't.
- `--qty` — quantity, default `1`.
- `--payment-token` — a tokenized payment credential (never a raw card number —
  `PaymentTokenGuard` in the core gem rejects those before they reach the wire).
  Omit for `--dry-run` or to just browse, or to fall back to whatever
  `portage payment` has on file as the default (see "Payment" below) — the
  flag always wins when both are present.
- `--product-id` — buy exactly this product rather than whatever the catalog
  search ranks first. If the id isn't in the results, nothing is bought.
- `--store` — name the merchant without giving a full URL; skips the search.
- `--max-price` — in major units (`400` means 400), compared per offer in that
  offer's own currency. No FX conversion. Applies per unit, to the search and
  to the store's own catalog once one is settled (a URL, `--store`, or a
  picked offer): nothing priced above it is checked out, even with
  `--product-id`. A product with no price is still eligible.
- `--limit` — how many candidate stores to probe, capped at 12.
- `--yes` — skip the confirmation prompt before completing checkout.
- `--dry-run` — resolve and price the order without completing checkout.
- `--decision-backend` — opt into the confidence gate (see "Decisions" below):
  `jev` or `laya`. Defaults to `PORTAGE_DECISION_BACKEND`; unset means off.
- `--min-confidence` — the gate's threshold, `0.0`–`1.0`. Defaults to
  `PORTAGE_MIN_CONFIDENCE`, then `0.8`. The flag is always checked; the env
  var is read (and checked) only while a backend is selected, so a stale
  value can't block a buy that doesn't use the gate.
- `--handoff-target default|print|profile|agent:NAME` — where a dead-end
  checkout's link goes. See "Hand-off targets and hand-off-only hosts" below.
- `--json` — machine-readable report instead of the human-readable summary.

Exits `0` when a checkout completed (or a dry-run/browse/search resolved
successfully), `1` otherwise — including the "no native manifest, no adapter
credentials" dead-end case, so it's scriptable in CI. A flag that can't be
used (an unreadable value, an out-of-range threshold) stops the buy before
anything runs: on stderr normally, or as a JSON report with `outcome:
"invalid_option"` under `--json`.

### Check

`portage check <url> [--json]` answers "can Portage buy from this store, and how?".
It checks for a native `/.well-known/ucp` manifest, detects the platform, notes
whether its adapter gem is installed and which env vars are missing, and looks for
WebMCP tools, using the same hand-off-only rules as `buy`. `verdict` is
`automated`, `webmcp`, `handoff` or `unsupported`, with a plain-English
`next_step`. Exits `0` for `automated` and `webmcp`. It sends plain GETs only, and
never contacts a hand-off-only host. WebMCP is read only from a tab your Portage
browser profile already has open on the store; it never launches a browser.
Takes the `--proxy*` flags.

### Compare

`portage compare <url> --product-id ID` finds other stores selling the same
item you already have. It resolves the named product, then runs `find`'s own
candidate-discovery/probe/rank pipeline against the product's title, scoring
each surviving offer instead of treating them all as equally confident hits:

- `--product-id` — required. The item to compare, at the store you name.
- `--id VALUE` — repeatable. A SKU, barcode (UPC/EAN/GTIN), or MPN you already
  know, matched case-insensitively against every candidate's own identity
  values. There's no way to tell the matcher which *kind* of identifier you
  passed — the wire format doesn't distinguish them — so it doesn't pretend
  to; passing one just adds it to the matching corpus. When omitted, the
  origin product's own first variant sku/barcodes are used instead.
- `--results N` — how many ranked offers to return, default 5. Applies after
  ranking, not before — a truncated result is always the *worst* N dropped,
  never an arbitrary N. The underlying probe cap (candidate origins checked,
  not results returned) stays `find`'s own limit and isn't exposed on this
  subcommand.
- `--max-price` — same semantics as `find`'s.

Every offer carries a `match:` tier so a caller never mistakes a coincidence
for a confirmed match:

| Tier | Means |
| --- | --- |
| `confirmed` | Origin and candidate share a barcode value (UPC/EAN/GTIN) — the one identifier the spec treats as globally unique. |
| `likely` | Origin and candidate share a SKU, or an explicit `--id` hit landed on the candidate — both are "some string matched", not "a global identifier matched", so they share one tier rather than a false precision gradient. |
| `unconfirmed` | Same search query, nothing shared. Could be the same item; could just have a similar title. |

The origin store itself is excluded from results, matched by host (not by
raw origin string), so an `http://`/`https://`/trailing-slash variant of your
own store's URL doesn't show up as a "competitor." A `www.` variant is
treated as a different host, same as `find`'s own candidate dedupe — worth
knowing if your store answers on both.

**Known limitation: recall, not ranking, is the ceiling.** Compare searches
the backends using the origin product's own title — a store-specific
marketing string. If a backend never surfaces the competitor for that title,
no amount of tiering helps; every offer that *does* come back may be
`unconfirmed` because nothing more specific was searched. There's no
barcode/SKU-keyed second search pass yet.

**Catalog-price only.** No `create_checkout` step runs against any candidate
store — ranking uses each store's listed price, never a landed price
(shipping/tax included). Verifying the actual cheapest landed price would
mean starting a checkout on a store the shopper hasn't chosen, which risks
abandoned carts on someone else's site; left out of scope for now.

### History

Every `portage buy` that creates a checkout is logged locally to
`~/.portage/history.json` as a purchase, whatever came of it. Each entry
carries the report's `outcome` (`purchased`, `dry_run`, `policy_blocked`,
...), what the checkout held (`items`), its `total`, and, when it wasn't
completed, the `checkout_url` to finish it. "What did I already buy" is
the entries whose `outcome` is `purchased`. A `buy` that never reached a
checkout (no match, browse-only, a dead end) is logged as a search at that
store instead, as is every `find`, `compare`, and the search behind a
`buy` with no URL. The most recent 200 entries of each are kept.

```bash
portage history                       # both lists, most recent last
portage history list --purchases      # just purchases
portage history list --searches --limit 20
portage history clear                 # wipe both
portage history clear --purchases     # wipe just one
```

This is a local convenience cache, not an audit log — `portage history clear`
deletes it outright, and there's no server-side record.

### Payment

Card-on-file storage for `--payment-token`, so an autonomous agent can
complete a checkout without a human handing over a fresh token every time
(docs/plans/agentic-payments.md Phase 1). No raw card number ever touches
this process — enrollment is a browser handoff to the gateway's own hosted
setup page:

```bash
portage payment enroll https://your-shop.example --label "Ops card"
# → prints a setup_url; visit it, enter the card there, this process polls
#   until the gateway hands back a token, then stores it.

portage payment list
portage payment set-default <id>
portage payment freeze <id>    # blocks spend, keeps the enrollment
portage payment revoke <id>    # deletes the token and the enrollment
portage payment remove <id>    # same as revoke — no processor-side
                                # "invalidate this token" call to differ by
```

`--scope-merchant`/`--scope-max-amount`/`--scope-currency` bind a Phase 2
policy scope to the token at enrollment time, rather than after the fact:

```bash
portage payment enroll https://your-shop.example --label "Ops card" \
  --scope-merchant your-shop.example --scope-max-amount 5000 --scope-currency USD
```

Written to `Policy` keyed by the same `token_ref` `PolicyGuard` derives from
the token at charge time — enrollment is the only place a scope gets
attached to a specific token; `portage policy set` below only touches the
global caps/velocity/allowlist, not per-token scopes.

Storage picks the strongest tier your platform actually has, in order, with
no homegrown fallback store of its own:

1. **macOS Keychain**, via the `security` CLI.
2. **Linux Secret Service** (GNOME Keyring/KWallet), via `secret-tool` — only
   when a D-Bus session is actually live.
3. **Headless** — no local storage at all. The token *is*
   `PORTAGE_PAYMENT_TOKEN`; `list`/`enroll`/`freeze`/etc. don't apply, since
   there's nothing local to manage.

**Local policy guards agent mistakes, not a compromised agent.** Anyone
running as the local user can read/edit `~/.portage/payment_methods.json` or
the Keychain/Secret Service entry directly — this is a convenience store, not
a security boundary. The real backstop against a rogue or compromised agent
is an issuer-side limit (a virtual card via Stripe Issuing, Privacy.com,
etc.), not anything in this gem.

### Policy

`portage policy show`/`set` manage the Phase 2 policy file
(`Portage::Ucp::Policy`, checked by `PolicyGuard` on every `complete_checkout`)
— top-level caps, velocity, and a merchant allowlist that apply regardless of
which token is spending:

```bash
portage policy show
portage policy show --json

portage policy set --per-transaction-cap 10000 --currency USD
portage policy set --rolling-cap 50000 --rolling-window-seconds 86400 --currency USD
portage policy set --velocity-count 5 --velocity-window-seconds 3600
portage policy set --allow shop.example.com --allow other-shop.example.com
portage policy set --clear-allowlist
```

Each `--*` group is applied independently — `portage policy set --allow
shop.example.com` touches only the allowlist, leaving caps/velocity as they
were, so caps and the allowlist can be configured in separate invocations.
An empty policy (nothing ever set) means every check passes; this is an
opt-in guardrail, not a default-deny one. Per-token scopes (merchant/amount
limits bound to one enrolled card) are set via `portage payment enroll
--scope-*` above, not here.

`portage policy set --require-approval person|any|off` (default `any`) sets what a
real `buy --yes` needs: `off` is `--yes` alone; `any` needs `--quote QUOTE_ID` for a
quote approved with `portage approve` (by the person, or relayed by an agent with
`--relayed-yes`); `person` needs the person's own yes at a terminal. Otherwise the run
is a dry run that returns `needs_approval`. Lowering the level asks for a yes at a
terminal. Stored as `require_approval` in `~/.portage/policy.json`. It raises the bar
against an agent but isn't a hard guarantee: a process with a shell can edit that file
or the quote files in `~/.portage/quotes/`. The whole flow (`find`, `pick`, `buy
--offer --dry-run`, `approve`, `buy --quote --yes`) is in the
[CLI JSON reference](../docs/api/cli-json.md) and the
[tutorial](../docs/cli-usage-tutorial.md#picking-and-approving-at-the-terminal). Upgrade
note: under the default `any`, `buy --yes` with no approved `--quote` no longer buys;
restore the old behaviour with `portage policy set --require-approval off` from a
terminal.

### Tiers: how a purchase actually finishes

Most stores don't let a third-party agent complete payment. `portage buy`
never pretends otherwise — it builds the cart/checkout it can, then hands
off through one of three tiers, from least to most involved:

| Tier | What | Default | Guardrail |
| --- | --- | --- | --- |
| A | Hand off to your own default browser; optionally seed the store index from your bookmarks/history (`portage browser import`) | Hand-off on; import opt-in | Domains only; you see and approve the imported list; nothing leaves the machine |
| B | A dedicated Portage browser profile drives the cart via WebMCP, then hands off there for you to pay (`portage browser profile`) | Off | Never your default profile; a domain allowlist (the store plus its checkout host); stops at payment — you click pay, your browser's own card autofill fills it |
| C | Hand-off-only hosts (Amazon, and any host you add) — Portage opens the page or a search/cart-add URL and you buy | On by default, host list is yours to edit | No scraping, no page reads, no UCP probe — just a URL, built not fetched |

**Never, in any tier:** Portage reading your browser's password, cookie or
autofill store; Portage attaching to your default browser profile; Portage
solving or bypassing a CAPTCHA; card data passing through Portage.

### Hand-off targets and hand-off-only hosts

Most checkouts end in a hand-off, not a `purchased` outcome — see the next
section. `--handoff-target default|print|profile|agent:<name>`
(`PORTAGE_HANDOFF_TARGET`, or `~/.portage/config.json`'s `"handoff_target"`)
decides where that link goes:

- `default` (Tier A) — opens it in your own browser. Today's behaviour:
  `--auto-open`/`--no-auto-open`, `PORTAGE_AUTO_OPEN_CHECKOUT`.
- `print` — just reports the URL.
- `profile` (Tier B) — drives the dedicated Portage browser profile (see
  "Portage browser profile" below) instead of your own. With no profile
  attached (not opened yet, or `portage-ucp-webmcp` isn't installed), it
  reports that and falls back to reporting the link.
- `agent:<name>` — hands the checkout URL and cart summary (items, qty,
  total, store — the same JSON `--notify-webhook` sends) to an external
  agent you've approved once in `~/.portage/config.json`'s
  `"handoff_agents"` (a command, run with a scrubbed environment and the
  payload on stdin, or an `https` webhook — never invoked unless
  `"approved": true`, and never given credentials, payment tokens or
  shipping details beyond what the checkout URL already holds).

An unrecognized value is a usage error (`invalid_option` under `--json`),
checked before the buy starts.

Amazon (every marketplace TLD), walmart.com, ebay.com and bestbuy.com
(unconditionally — no adapter, no UCP for any of them to opt back into), and
any host in `~/.portage/config.json`'s `"handoff_only_hosts"` are **Tier C,
hand-off only**: `portage buy` never sends that host a request at all — no
UCP probe, no page fetch, no cart — it opens the page (or a cart-add/search
URL when a product id is known) and you buy it yourself. Absent that config
key, the default list is every Amazon marketplace; once present, your list
*is* the list — drop Amazon or add another host, and removing one only
changes the message, since there's no code here that automates a site
without UCP or WebMCP. `find`, `index build` and `browser import` all skip
probing a hand-off-only host too, though they may still list it as a
candidate you already know about. `portage doctor` reports the current
target and host list. **Portage is open-source software provided as-is,
without warranty of any kind (MIT)** — how it's used on any site, and
compliance with that site's terms, is your own responsibility.

### Categories and routing

`portage find` classifies your query and a store's title/description/URL
slug against `known-stores/categories.yml` (the top two levels of Google's
published product taxonomy, ~200 nodes shipped in the gem;
`~/.portage/categories.yml` overrides or extends it). A tagged
`stores.yml`/index entry (`{url:, categories: [...]}`) only spends one of a
query's probe slots when its categories actually match — capped at 3 stores
per category and 12 total — so a large personal allowlist or a big local
index doesn't crowd out the store that actually sells what you asked for. An
entry with no matching category is still reached when you name it by host or
brand.

### Local store index (`portage index`)

A fresh install only knows the stores you type into `stores.yml` or that a
search backend returns for one query. `portage index` gives `find` a
standing, local list of stores and products to route queries to instead,
built from sources you can read (`portage index sources`):

```bash
portage index build                          # every default source
portage index build --sources shopify_catalog,stores_file
portage index build --queries queries.txt    # one query per line, instead of the built-in taxonomy sweep
portage index refresh                        # re-verify entries older than 7 days, add new ones
portage index show --stores --json
portage index show --products --page 2 --json   # 50 a page; --per-page N
portage index search "wall light" --store some-shop.example --json
portage index add https://some-shop.example
portage index add https://some-shop.example --crawl   # also read its /products.json catalogue
portage index build --sources storefront_products     # crawl the catalogues of stores already indexed
portage index remove some-shop.example
portage index sources                        # name, what each fetches, source file path
```

Stored in `~/.portage/index/index.sqlite3` (mode 0600), **never in git** and
**never containing a price or stock field** — those are always fetched live.
Each new origin gets exactly one `/.well-known/ucp` probe (capped at 500 new
probes per run), throttled, with progress output. Sources:

| Source | Fetches | Default |
| --- | --- | --- |
| `shopify_catalog` | Merchant origins and product identities, one query per top-level taxonomy node, from `catalog.shopify.com`'s open catalog | on |
| `stores_file` | Your own `~/.portage/stores.yml` | on |
| `browser` | Whatever `portage browser import` (below) already saved — this source itself never reads a browser | on, but yields nothing unless you've run `browser import` |
| `wikidata` | Retailers'/brands' official sites via a public SPARQL query | opt-in (`--sources wikidata`) |
| `webmcp_sweep` | Which WebMCP preset an origin matches, when a bridge is attached | opt-in, needs a bridge |
| `storefront_products` | Each indexed Shopify store's own `/products.json`: title, brand, handle, URL, first image, options and variant ids, mapped through the UCP `Product` shape with price and availability dropped | opt-in (`--sources storefront_products`, or `index add URL --crawl`) |

**Catalogue crawls are polite and opt-in.** `storefront_products` never runs
from `find` or `buy` (`portage check` only prints the `index add ... --crawl`
command). It crawls at most 20 pages of 250 products a store and 25 stores a
run, least recently crawled first, 1s apart. It waits out one 429's
`Retry-After` (capped at 60s) and stops that store on a second. It obeys
`robots.txt` for every page URL, never contacts a hand-off-only host, and
skips a store that answers 404, a redirect or anything but products JSON (a
bot wall). What happened is kept on the store entry as `crawl`.
`portage index search` then searches those products locally (SQLite FTS5,
or a plain text match if FTS5 is missing), with no request.

**The index is untrusted data, on the same footing as any other `find`
candidate.** It never feeds `Policy#merchant_allowlist` and never counts as
"you picked a store" for `--yes` — a search ranker (which an index entry
still is) never gets to complete a purchase on its own.

**Known-stores, fetched, not built by you.** The repo itself publishes
`known-stores/{stores,products}.json` — built the same way, just by the
maintainer — over jsdelivr's `@main` CDN. `find` uses it automatically
(cached at `~/.portage/index/known-*.json`, refreshed on `index
build`/`refresh` or when `doctor` sees it's more than 7 days stale) even
before you ever run `index build` yourself; your own entries always win over
it on a conflict. `index build --export DIR` writes a PR-ready copy with
personal (browser-derived) entries stripped, for anyone who wants to
contribute a store they found to the shared list.

### Browser import (Tier A)

```bash
portage browser import --dry-run --json
portage browser import --browser chrome --history-days 90 --max-probes 200
portage browser import --yes --exclude some-domain-you-declined.example
```

Reads your browser's bookmarks and history — Chromium family's `History`
(SQLite)/`Bookmarks` (JSON), Firefox's `places.sqlite`, Safari's
`History.db`/`Bookmarks.plist` (needs Full Disk Access on macOS; the command
explains the prompt and never works around it) — reduces every row to a bare
domain, and decides each one locally first against the hand-off-only list,
the local index and the known-stores cache before spending one of at most
`--max-probes` (default 200) `/.well-known/ucp` probes on an unknown one.
Kept domains are classified (page titles, bookmark folder names, URL slugs)
into the same categories `find` routes by, weighted by visit count.
**Nothing is saved without your approval:** a dry run (or any non-interactive
run without `--yes`) only shows what it *would* keep; `--yes` (after you've
reviewed the list, optionally with `--exclude host,host` for ones you don't
want) writes them to the local index as `sources: ["history"]`/`["bookmark"]`
entries. `--include-product-pages` (off by default) also keeps product page
titles/URLs as product entries.

**Never reads cookies, saved passwords, or autofill data**, on any browser —
only the two files named above, verified by a spec that opens a fixture
profile full of `Login Data`/`Cookies`/`Web Data` decoys and asserts none of
them were touched.

### Portage browser profile (Tier B)

```bash
portage browser profile init      # create the dedicated profile directory
portage browser profile open      # launch it, remote debugging on
portage browser profile status
```

A dedicated Chromium-family profile (Chrome, Edge, Brave or Arc — Firefox
and Safari aren't supported for driving) under `~/.portage/browser/`,
launched with remote debugging scoped to *that* profile only — never your
default one; Chrome 136+ refuses remote debugging on the default profile
anyway. Sign into your shopping sites there once. With
`portage buy ... --handoff-target profile`, the cart is built in this same
browser via WebMCP (when the store supports it) and the checkout opens there
for you to pay — driving is limited to a domain allowlist (the store being
bought from, plus its checkout host); navigating anywhere else stops the
run. Payment is filled by the browser's own saved-card autofill, triggered
by your own gesture — Portage never touches a payment field and never
clicks pay. Requires `gem install portage-ucp-webmcp`.

### Retailer offer sources

Official, opt-in buyer-side APIs that add more real offers to `portage
find`, each gated on its own key set in `~/.portage/.env` (or via `portage
setup`, below):

| Retailer | Env var |
| --- | --- |
| Walmart Affiliate API | `WALMART_AFFILIATE_API_KEY` |
| eBay Browse API (Buy It Now only) | `EBAY_BROWSE_ACCESS_TOKEN` (optional `EBAY_MARKETPLACE_ID`) |
| Best Buy Products API | `BESTBUY_API_KEY` |
| Etsy Open API v3 (buyer-side `findAllListingsActive`) | `ETSY_LISTINGS_API_KEY` |
| Amazon Creators API | `AMAZON_CREATORS_ACCESS_TOKEN` (optional `AMAZON_CREATORS_MARKETPLACE`) |

With none set, `find` behaves exactly as it did before these existed. Every
offer from any of these five still ends in hand-off — none of them has a
checkout `portage buy` can drive, so walmart.com/ebay.com/bestbuy.com are
hand-off only unconditionally and Amazon/Etsy follow the rules in "Hand-off
targets and hand-off-only hosts" above (Etsy only when *your own* seller
credentials aren't already configured for `portage-ucp-etsy`). `portage
doctor` reports which of the five are active.

### The `portage setup` wizard

On a TTY, `portage setup` (or `portage doctor`/`portage configure` when
nothing is configured yet) walks through setup interactively, one skippable
step at a time, never echoing a secret back: shipping address, search API
keys, retailer offer source keys, the agent profile, browser import, index
build, spending policy caps, and hand-off target/hand-off-only hosts. Each
step delegates to the real command it configures — nothing is
reimplemented — so it behaves exactly like running that command yourself.
Under `--json`, or with no TTY on stdin (piped, CI, or a tool call), `setup`
never prompts: it prints exactly `doctor --json`'s read-only report.

### Orders reconcile

Nearly every real checkout `portage buy` can't finish itself hands the
shopper a link — `requires_escalation`, `permission_denied`,
`no_payment_token`, `policy_blocked`, `low_confidence`, or
`checkout_mismatch`. That's a pending purchase this process knows nothing
more about until something asks the store. `portage orders reconcile`
re-fetches each pending hand-off from the store and settles it once the
store itself reports a terminal status:

```bash
portage orders reconcile              # every pending hand-off
portage orders reconcile --checkout chk_123
portage orders reconcile --json
```

A `completed` checkout settles `complete` — using the store's own total at
settle time, not the hand-off-time snapshot — records the order (when one
exists) and a journal entry, and is counted toward your spend policy's
rolling cap/velocity per `handoff_spend_mode` below. A `canceled` checkout,
or one that expires with no answer, settles `failed`. Anything still
in-progress, or not currently reachable, is left pending for the next run —
safe to put on a cron/launchd schedule; two overlapping runs never
double-settle the same record.

`handoff_spend_mode` (`PORTAGE_HANDOFF_SPEND_MODE`, config.json's
`handoff_spend_mode`) controls whether a reconciled shopper purchase counts
toward the caps `portage policy set` configures:

- `block` (default) — counts like any agent-completed purchase.
- `warn` — recorded, but excluded from the cap/velocity math; still notifies
  when it would have pushed spend over the cap.
- `precheck` — `block`, plus a spend-cap check at hand-off time
  (`portage buy`, not reconcile): if this checkout's total would already
  exceed your cap, the URL is still printed but auto-open is suppressed.

`--wait [--wait-timeout DURATION|off]` on `portage buy` polls the same
reconciler right after a hand-off, instead of waiting for a separate
`orders reconcile` run. It backs off (2s → 30s, plus jitter) until the
checkout settles or its deadline passes — the earlier of
`handoff_wait_timeout` (`PORTAGE_HANDOFF_WAIT_TIMEOUT`, config.json; default
`30m`, `off` removes it) and the checkout's own `expires_at`. Ctrl-C, or
the deadline, leaves the record pending for a later `portage orders
reconcile` — it never settles from the wait itself. Under `--wait --json`,
stdout streams NDJSON — `handoff`, `handoff_status` on each store-reported
status change, `handoff_settled` — followed by the final report object;
plain `--json` without `--wait` is unchanged.

`reconcile_notify` (`PORTAGE_RECONCILE_NOTIFY`, config.json's
`reconcile_notify`) is a comma list of channels a settled hand-off notifies
on, from `--wait` or `orders reconcile`: `webhook` (default), `macos` (a
native notification), `terminal` (a printed line — forced on for a
plain-text `--wait` regardless of configuration), and `journal` (the order
snapshot journal write, already unconditional — listing it just documents
that).

### Doctor

```bash
portage doctor          # alias: portage configure
portage doctor --json
portage setup           # same report, but interactive on a TTY — see below
```

Checks this machine's setup without touching the network (apart from
probing any proxy you've configured). It first reports how Portage is
installed, then lists anything that needs fixing:

- `install`: `homebrew` (with the Cellar path) or `gem` (with the gem's
  path).
- `runtime`: the Ruby version and path it runs on, and the `portage-cli`
  version.
- `adapters`: which first-party adapter gems load, and at which version.
  Missing adapters are expected on a gem install; on Homebrew, which
  bundles them all, a missing one is a warning.
- `path`: which `portage` your shell actually runs. Warns when another copy
  earlier on `PATH` shadows this one (see "Two copies on PATH" above).
- `shipping`: warns when `PORTAGE_SHIP_*` is missing or incomplete (see
  "Shipping address" below), naming the variables to set.
- `env_file`: which env file was loaded (see "Environment file" below).
  Warns when other users can read it.
- The confidence gate's backend, the User-Agent, and proxy settings.
- `index`: local and known-stores index counts and staleness (see "Local
  store index" below).
- `handoff`: the current `--handoff-target` default and the hand-off-only
  host list, plus the as-is/no-warranty disclaimer.
- `retailer_offer_sources`: which of the five retailer offer source keys are
  set, and a reminder that none of them can complete a purchase.
- Seller-side checks against `Portage::Ucp.configuration` (authenticator,
  rate limiter, signing keys, payment handlers). These only run when you
  pass `--require` with your app's initializer (Rails:
  `--require ./config/environment`) or `--adapter`. Without them doctor
  would only ever see the unconfigured defaults, so it just notes that it
  skipped them.

With `--json` the output is an array of findings, each with `check`,
`message`, `level` (`warning` or `info`) and, for the install checks,
`details`. Doctor exits `1` when there's at least one warning, else `0`.

### Proxy

`buy`, `find`, `compare`, `doctor`, and `payment enroll` accept the flags below,
resolved (per field, flag > env > `~/.portage/config.json`) into a
`Portage::Ucp::Support::ProxyConfig` by `Portage::Cli::ProxySettings` — see
[`docs/proxy.md`](../docs/proxy.md) for corporate egress, a rotating residential
pool, an API gateway, mitmproxy for debugging, and nginx/Cloudflare in front of the
MCP/WebMCP endpoints, worked through end to end.

| Flag | Meaning |
| --- | --- |
| `--proxy URL` | The default proxy's URL (`http://user:pass@host:port`). Overrides only `proxy.default.url`; every other configured field (`no_proxy`, `routes`, `chains`, ...) stays as set in config.json. |
| `--proxy-mode forward\|gateway` | The default profile's mode. `forward` (the default) is a standard HTTP proxy; `gateway` is a URL-rewriting gateway — see `docs/proxy.md`. |
| `--proxy-header "Name: value"` | Repeatable. Sent only to the proxy (on the `CONNECT` request, or the gateway request) — never to the real target. `Authorization`/`User-Agent`/`X-Shopify-*-Access-Token`/`X-Payment-Token` are refused here, always. |
| `--no-proxy HOSTS` | Comma-separated hostnames/suffixes/CIDRs (or a bare `*`) to always bypass the proxy for, whatever the route resolves to. |
| `--proxy-route ROUTE=URL\|direct` | Repeatable. Points one fixed route (`store`, `search`, `notify`, `payment`, `platform`, `probe`) at its own URL, or forces it `direct` regardless of `default`. |
| `--proxy-chain URL,URL,...` | An ad-hoc multi-hop chain for this run — each hop is `forward` unless prefixed `gateway+https://...`. Overrides the whole `default` profile (not just its `url`), since a chain has no single "url" field to merge with config.json's own. |
| `--proxy-passthrough HEADER` | Repeatable, server commands only. Allowlists an inbound request header to ride along on outbound calls made while serving it — see `docs/proxy.md`'s passthrough section. Refuses a protected header name at parse time. |
| `--proxy-ca FILE` | A PEM file trusted in addition to the system store — for a TLS-intercepting corporate proxy or a debugging proxy like mitmproxy. |
| `--no-env-proxy` | Ignore `HTTPS_PROXY`/`HTTP_PROXY`/`NO_PROXY` (and their lowercase forms) entirely for this run — otherwise they're still the fallback for any route nothing else configured. |

**Env vars** (checked when the matching flag is absent, before config.json):

| Var | Matches |
| --- | --- |
| `PORTAGE_PROXY` | `--proxy` |
| `PORTAGE_PROXY_MODE` | `--proxy-mode` |
| `PORTAGE_NO_PROXY` | `--no-proxy` |
| `PORTAGE_PROXY_CA` | `--proxy-ca` |
| `PORTAGE_PROXY_HEADERS` | A JSON object of header name → value, merged under any `--proxy-header` flags (flags win on a name collision). |

Below all of the above, the standard `HTTPS_PROXY`/`HTTP_PROXY`/`NO_PROXY` (and
lowercase) variables are still the fallback for any route nothing here configures
at all — existing environments keep working unless `--no-env-proxy` is set. The
**`payment` route is always forced `direct`** unless a proxy is named for it
explicitly (`--proxy-route payment=...` or config.json's `routes.payment`) — it
never inherits a bare `default`/env proxy the way every other route does, so an
egress proxy nobody meant to hand payment tokens to never sees them by accident.

`${ENV_VAR}` inside a config.json header value (`proxy_headers`, `forward_headers.add`)
is expanded from the process environment at resolve time, so a secret can live in
the environment rather than the file itself. A proxy password can also live in
`password_ref` (resolved through the same macOS Keychain/Linux Secret Service tiers
`portage payment` uses, under its own `portage-cli-proxy` service name) instead of
plaintext in the URL — `portage doctor` warns when it finds a plaintext one anyway.

`portage doctor` reports, per route, what's effectively configured (credentials
redacted), whether each configured proxy/gateway is actually reachable, and flags
plaintext proxy credentials and an intercepting proxy (`ca_file` or `gateway` mode)
sitting on the `payment` route.

### WebMCP (library use, opt-in)

`portage buy` from the shell has no browser of its own, so there's no CLI
flag for this — it's for a caller embedding `Portage::Cli::Buy` directly
alongside its own browser automation:

```ruby
Portage::Cli::Buy.new(url: "shop.example", query: "mug",
                      webmcp_bridge: my_portage_ucp_webmcp_bridge).call
```

Given a `portage-ucp-webmcp` outbound bridge already pointed at a navigated
page, `Buy` tries it after native-UCP discovery finds nothing at that URL
and before falling back to a platform adapter. `webmcp_checkout_mode`
(`PORTAGE_WEBMCP_CHECKOUT_MODE`, config.json's `webmcp_checkout_mode`)
controls how it finishes: `express_stop` (default) builds the cart/checkout
and always hands off — reason `express_stop`, so `--wait`/`orders
reconcile`/`handoff_spend_mode` all apply exactly as they do to any other
hand-off. `token` isn't implemented yet; it reports
`webmcp_token_unsupported` rather than attempting completion. Requires
`gem install portage-ucp-webmcp` — not a hard dependency of `portage-cli`.

Against a page whose tools aren't a known platform preset, `Buy` falls back
to a schema-matched, shopper-confirmed mapping instead of giving up (see
`portage-ucp-webmcp`'s README, "Stores that don't run Portage"). A mutating
match prompts on a real TTY with `--json` off. Under `--json`, or with no
TTY, it stops instead: outcome `webmcp_mapping_unconfirmed`, with the
proposal in `tool_names_proposal`.

No flag passes a mapping back. From the CLI, re-run the same command in
your own terminal without `--json` and answer the prompt. `--dry-run` is
enough, because the mapping is confirmed before the dry-run check. The
approved mapping is saved to `~/.portage/webmcp_mappings.json`, and later
runs reuse it with no prompt.

`Buy` has no `tool_names:` keyword either. A library caller has two hooks.
`webmcp_mapping_confirm:` takes any object whose `call(proposal, tools)`
returns a `tool_names:` hash, or nil to stop with
`webmcp_mapping_unconfirmed`. `Buy` saves whatever hash it returns to
`webmcp_mappings:`, the store approved mappings are read from (default: a
`Portage::Cli::WebmcpMappings` on `~/.portage/webmcp_mappings.json`).
Outside `Buy`, pass `tool_names:` to `Portage::Ucp::WebMcp.connect`
yourself.

`dry_run: true` against a page whose preset hands off through its own
checkout tool (Shopify's `proceed_to_checkout`) stops after the read-only
product search: nothing is added to the store's cart, the tab isn't sent to
checkout and nothing is autofilled. The `dry_run` report carries a `would:`
key with the line item, the hand-off tool and whether autofill would run.
Because it builds no cart, it can't check one, so it never carries
`checkout_mismatch: true`.

A real run against that kind of page reads the cart back after adding to it
and checks it the same way `buy` checks any checkout (item, quantity, unit
price, currency, extra lines). Any mismatch stops the run there, with outcome
`checkout_mismatch` and `decisions.escalation.reason: "mismatch"`: the
hand-off tool isn't called, so the tab never goes to checkout, and nothing is
autofilled. The cart is already on the store, so `checkout_url` is the
store's `/cart` page, for the shopper to look at. Items already sitting in
the store's cart count as extra lines, so they stop the run too.

The same run then applies the other gates a checkout gets before anything
leaves the cart: a `--quote` run's cap (`quote_changed`), and, when a
decision backend is enabled, the confidence check (see "Decisions"). A hold
from the confidence check reports `low_confidence` with the `/cart` page as
`checkout_url`; again the tab isn't sent to checkout and nothing is
autofilled.

Once the flow hands off to the store's own checkout page, the shopper can
opt into having it pre-filled: `--autofill`, or
`PORTAGE_WEBMCP_AUTOFILL=approve` / config.json's `"webmcp_autofill":
"approve"` (only that literal string turns it on — a generic truthy value
doesn't). Even opted in, nothing is typed until a second prompt shows the
shopper exactly which fields and values are about to be entered and they
approve it — refused outright under `--json` or no TTY. It only ever
touches contact email and shipping address (from `PORTAGE_SHIP_*`/the new
`PORTAGE_SHIP_EMAIL`) plus the cheapest shipping rate it can find; it never
touches a payment field and never clicks submit/pay, and the run still
always ends in the same `express_stop` hand-off. A headless browser (or one
that never says) reports `autofill_needs_headed_browser`; a CAPTCHA/
challenge on the page reports `autofill_blocked` — see
`portage-ucp-webmcp`'s README, "Approved autofill of the store's checkout",
for the full field/outcome list.

### Decisions

`portage buy` and `portage find` make their judgment calls
(`docs/plans/system-one-decision-layer.md`) through rules that live in
`portage-ucp` core: `Support::OfferRanking`, `Support::Escalation` and
`PolicyGuard`. `portage-ucp-decision` wraps the same modules as typed
verdicts, so ranking, escalation and the policy check answer the same way
whether or not it's installed. It's an optional plugin, not a dependency:

```bash
gem install portage-ucp-decision   # only needed for the confidence gate
```

The confidence gate is the one feature that needs the gem, because the
model backends live there.

Every `portage buy` report carries an `outcome`, so a script or agent loop
can branch on data rather than on the message text. The text output leads
with the same value, as `[outcome]`.

| `outcome` | Meaning | `checkout_url`? |
| --- | --- | --- |
| `purchased` | Completed. | no |
| `needs_confirmation` | Checkout ready; rerun with `--yes`. | no |
| `dry_run` | Checkout created, `--dry-run` stopped it. `checkout_mismatch: true` when a real run would stop on a mismatch. | no |
| `requires_escalation` | The store wants the shopper to finish. | yes |
| `checkout_mismatch` | Checkout differs from the request (item, quantity, unit price, currency, or a priced line nobody asked for); stopped before payment. | yes |
| `no_payment_token` | No `--payment-token` and no default payment method. | yes |
| `policy_blocked` | Your spend policy denied it; `decisions.policy.reason` says why. | yes |
| `low_confidence` | The confidence gate held it (before a `--yes` completion, or before a WebMCP preset hand-off to checkout). | yes |
| `permission_denied` | The store doesn't let this agent complete checkout. | yes |
| `handoff_only` | Tier C: Amazon or another hand-off-only host. `legal_notice` explains why; see "Hand-off targets and hand-off-only hosts". | yes (built, never fetched) |
| `store_refused` | The store refused a cart/checkout call (e.g. sold out). | when the store gave one |
| `no_match` | Nothing in the store's results matched. | no |
| `browse_only` | The store has a catalog but no UCP checkout. | when an adapter offers a link |
| `agent_profile_missing`, `request_rejected`, `unsupported_wire_shape` | Native UCP setup problems; the message names the fix. | no |
| `adapter_error`, `adapter_misconfigured` | Your own-store adapter failed; the message quotes it. | no |
| `dead_end` | No UCP and no adapter for this store. | no |
| `invalid_option` | A flag was refused before the buy started (`--json` only); `message` says which. | no |

Checkout reports also carry `items` (what the checkout holds, as opposed to
`products`, the search results) and the verdicts under `decisions:`:

```json
"decisions": {
  "escalation": { "escalate": false, "reason": null },
  "policy":     { "allowed": true, "reason": null },
  "confidence": { "proceed": false, "reason": "below_threshold", "confidence": 0.41,
                  "threshold": 0.8, "backend": "jev", "error": null }
}
```

Every verdict has a `reason`: `null` when the gate let the purchase through,
otherwise a string naming why it stopped it.

- **escalation** — `Support::Escalation`. A `requires_escalation` checkout
  always escalates (`reason: "requires_escalation"`). So does a checkout that
  doesn't match the request (`reason: "mismatch"`), on every run but
  `--dry-run`, where the mismatch is reported in `warnings` and flagged with
  `checkout_mismatch: true` instead. Nothing turns this off:
  `PORTAGE_ABORT_ON_CHECKOUT_MISMATCH` is deprecated and ignored. A mismatch
  is the requested line missing, a different quantity, a different unit
  price or currency than the store's own catalog, or any extra line the
  request didn't include. An extra line that costs nothing (a free gift, a
  $0 sample) is allowed; one whose cost can't be read counts as priced.
- **policy** — `PolicyGuard`, run on your policy file (see "Policy" above)
  before any `--yes` completion. `reason` is the guard's own
  (`per_transaction_cap_exceeded`, `rolling_spend_cap_exceeded`,
  `velocity_exceeded`, `merchant_not_allowlisted`, `token_scope_merchant`,
  `token_scope_amount`, `currency_mismatch`, or `total_unknown`, below).
  It applies to remote native-UCP stores too. Before this check, only the
  own-store adapter flow's in-process `Dispatcher` enforced the policy.
  Rolling caps and velocity limits count the completed purchases at that
  merchant in `~/.portage/transactions.json`. `Dispatcher` records
  own-store purchases there, and `portage buy` records remote ones: reserved
  before the store is asked to complete, then settled as `complete` only
  when the store answers that it's purchased.
- **confidence** — `ConfidenceGate`, off unless `--decision-backend` or
  `PORTAGE_DECISION_BACKEND` names a backend. Right before a `--yes`
  completion, and before a WebMCP preset flow sends the browser to the
  store's checkout (and autofills it), it asks the backend whether the
  checkout matches the request, and the approved quote on a `--quote` run,
  and is safe to complete unattended. It is additive only: it runs after
  the mismatch check, the quote cap and the spend policy, on a checkout all
  of them let through, so it can hold a purchase but never let through one
  they would stop. The gate fails closed, so three things hold the
  purchase: a score below the threshold (`reason: "below_threshold"`), a
  backend that can't answer or answers with something that isn't a
  probability (`"backend_error"`), and naming a backend without
  `portage-ucp-decision` installed (`"not_installed"`). For the last two,
  `error` says what went wrong. `jev` needs `JEV_API_KEY`; `laya` needs
  `LAYA_BRIDGE_SCRIPT` (see `portage-ucp-decision`'s README). `portage
  doctor` flags whichever of these is missing for the selected backend.

  `jev` is TypeSafe's hosted API, so what it's sent is kept to a minimal,
  allowlisted summary (`Portage::Cli::ConfidenceState`); nothing else on
  the checkout is read:

  - `request`: the search query, the store's host, the quantity, and the
    picked item's id and title.
  - `approved_quote` (`--quote` runs only): the quote's store, product id,
    title, quantity, total and currency.
  - `checkout`: status, currency; per line, item id, title, unit price,
    quantity, line totals and whether it's the requested line; the totals
    (subtotal, shipping, tax, fees, total — whatever the store lists);
    applied discounts' titles and amounts; the selected shipping option's
    title and price.
  - `warnings`.

  Never sent: the payment token, the shipping address, the buyer's name,
  phone or email, checkout ids, links and URLs, discount codes, or anything
  from your environment. Store-supplied strings are cut to 200 characters.
- **policy** also denies a checkout with no `total` line as
  `total_unknown` whenever a spend cap is set, rather than skipping the cap.

A blocked or held purchase hands the checkout off the same way an escalation
does (`checkout_url`, plus `--auto-open`/`--notify-webhook` if set). The
shopper can finish it themselves. The webhook body is JSON: `event`
(`checkout_handoff`), `reason` (the report's `outcome`), `message` (the
report's own sentence), `store`, `query`, `checkout_url`, `checkout_id`,
`source`, `totals` and `warnings`. Any 2xx counts as delivered; the POST
gives up after 5 seconds and reports `notify_error` instead.

`portage find`'s offer order comes from `Support::OfferRanking`: buyable
first, then cheapest, then unpriced.

### Environment file

`portage` and `portage-console` load `~/.portage/.env` on startup, so your
shipping address, search keys and adapter credentials can live in one file
rather than your shell profile. `.env.example` at the repo root lists every
variable. Rules:

- Variables already set in your shell win over the file.
- Empty values are skipped, so blanks copied from `.env.example` set nothing.
- `KEY=value`, `export KEY=value`, `"double"` (with `\n` and `\"` escapes) and
  `'single'` quotes all work; `#` starts a comment.
- `PORTAGE_ENV_FILE=path` loads a different file instead, for example
  `PORTAGE_ENV_FILE=.env` for a project checkout's own.

Keep it private (`chmod 600 ~/.portage/.env`); `portage doctor` warns if
other users can read it.

#### Why `./.env` is never loaded automatically

Many tools load a `.env` from whatever directory you run them in. Portage
deliberately doesn't, because `portage` spends money and handles payment
tokens, and the directory you happen to be in isn't something you chose
to trust. If it did, running `portage` inside a cloned repo, a downloaded
project or a shared folder would silently apply that directory's
settings, for example:

- `PORTAGE_PROXY` plus `PORTAGE_PROXY_CA`, routing your store traffic
  through someone else's intercepting proxy, where they can read it;
- a notify webhook that sends your checkout URLs and order details to
  someone else;
- store credentials or `PORTAGE_STORES`, pointing purchases at a different
  store than you think.

So only `~/.portage/.env`, a file you created in your own Portage
directory, loads automatically. To use a project's `.env`, name it on
purpose: `PORTAGE_ENV_FILE=.env portage ...`, after reading what's in it.

### Shipping address

Set your shipping address in `~/.portage/.env` (or your shell) rather than
a flag, the same way as adapter credentials. `portage doctor` warns until
the required ones are set:

```bash
PORTAGE_SHIP_STREET="1 Main St"
PORTAGE_SHIP_CITY="Erie"
PORTAGE_SHIP_REGION="PA"          # optional
PORTAGE_SHIP_COUNTRY="US"
PORTAGE_SHIP_POSTAL_CODE="16501"
PORTAGE_SHIP_FIRST_NAME="Ada"     # optional
PORTAGE_SHIP_LAST_NAME="Lovelace" # optional
PORTAGE_SHIP_PHONE="+1..."        # optional
```

`street`/`city`/`country`/`postal_code` are required — a partial profile
(or one with empty values) is treated as no profile at all.

The variables are used in two ways:

- **Native UCP stores** (`buy` and `find` over HTTP) get
  `PORTAGE_SHIP_COUNTRY`, `_REGION` and `_POSTAL_CODE` (plus
  `PORTAGE_CURRENCY` and `PORTAGE_LANGUAGE`, if set) as UCP buyer context,
  which a store uses to pick the market it prices and stocks in. These
  work on their own, without the full address.
  Without at least the country, a live Shopify store can report in-stock
  items as out of stock.
- **Your own store** (`portage buy`'s adapter-credentials fallback,
  described at the top of this file), when its adapter supports
  `dev.ucp.shopping.fulfillment`, also gets the full address as the
  checkout's shipping destination. Once the merchant prices shipping
  options against it, `portage buy` auto-picks the cheapest per fulfillment
  group; there's no interactive rate picker, since this drives one
  automated purchase. Native (non-adapter) UCP stores don't get the full
  address yet — see `portage-ucp`'s design log for why.

## Buying without a URL

`portage find` and URL-less `portage buy` share one pipeline:

1. **Ask the backends** which stores might sell it (see below).
2. **Probe each candidate origin** for `/.well-known/ucp`, one request each,
   throttled, with results cached in `~/.portage/discovery-cache.json` (misses
   for a day, hits for six hours) so repeat searches don't re-probe the same
   hosts. A tool that fans out an unsolicited request per host per invocation
   is a crawler; this one isn't.
3. **Search the survivors' catalogs** and merge the offers, buyable stores
   first, then cheapest.

**`--yes` is not enough to buy from a search result.** With a URL you chose the
merchant; without one a search ranker chose it, so the merchant has to be named
by a person — either `--store`, or an interactive pick from the listed offers.
A piped or CI run with no `--store` prints the offers and stops.

### Search backends

Every backend talks to a documented API. None of them parse a results page:
scraping a search engine is the same class of ToS violation `portage buy`
already refuses to commit against a merchant.

| Backend | Credentials | Notes |
| --- | --- | --- |
| Allowlist | `~/.portage/stores.yml` (YAML array of URLs, optionally tagged `{url:, categories: [...]}`) or `PORTAGE_STORES` (comma-separated, untagged) | Stores you already trust. Checked first, costs no network call. Tagged entries are routed by category (see "Categories and routing" above); untagged ones are always a candidate. |
| Index | `~/.portage/index/` (your own `portage index build`) plus the repo's published known-stores list | Ranked between Allowlist and DuckDuckGo. Sits out entirely until an index actually exists — a fresh install's behavior is unchanged. Also matches a query against an indexed *product* by name or GTIN, not just a store. |
| DuckDuckGo | none | The [Instant Answer API](https://api.duckduckgo.com/api). Answers *entity* queries, not web queries: `burton snowboards` resolves to burton.com, `snowboard` resolves to nothing. |
| Brave | `BRAVE_SEARCH_API_KEY` | Real web results. Set this up if you want open-ended queries to work. |
| Google | `GOOGLE_CSE_KEY` + `GOOGLE_CSE_CX` | Programmable Search JSON API. |

Backends that have no credentials sit out; DuckDuckGo is the keyless default
because it's the only no-key engine with a real API, and its narrowness is the
price of not scraping.

Separate from all of the above, `portage find`/`buy` also merge in offers
directly from `OfferSources` — `ShopifyCatalog` (no key,
`catalog.shopify.com`'s open catalog, always on) and the retailer offer
sources (opt-in, keyed — see "Retailer offer sources" above). These skip the
origin-probe step entirely, since a catalog result already names the
merchant's own product page.

### Console

`portage-console` is a separate executable — a read-only IRB REPL over the
three local `~/.portage` stores (design-log §22 item 6): `TransactionLog`
(reserve/complete records), `OrderLedger` (settled-order snapshots), and, if
you've wired `journal:` into your own `Dispatcher` (nothing in this gem does
that for you), the `portage-ucp-journal` gem's `PurchaseJournal`.

```bash
portage-console
```

```ruby
transactions                       # every reserved/completed transaction
transactions(shop: "your-shop.example")
find_transaction("idem_key_123")
transactions_since(Time.now - 86400, shop: "your-shop.example")

orders                             # every settled-order snapshot
find_order("order_123")

journal                            # empty unless a Dispatcher was built with journal:
```

Every result is passed through `Portage::Ucp::Observability.redact` before
it's returned — `payment_token`/`oauth_token`/`Authorization` and the PII
fields on an order's fulfillment destinations never print, even in a REPL you
trust. This is deliberately a local REPL, not the admin/web panel design-log
§16 also describes: a browser is a new place for a token to leak, and the
process holding a web panel also holds this machine's live platform admin
credentials in its env — problems a REPL run by whoever already has shell
access to this machine doesn't have.

## Development

```bash
bundle exec rspec
bundle exec rubocop
```

## License

[MIT](LICENSE) — Copyright (c) 2026 Tom Whitbread.
