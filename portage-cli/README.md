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

Already have the item and want to know where else it's sold? `portage compare`
resolves a product you name by URL + product id, then runs the same
find pipeline against its title and ranks the results by how confident the
match is:

```bash
portage compare https://your-shop.example --product-id prod_123 --results 5
```

Depends on [`portage-ucp`](https://github.com/tomtom87/Portage/tree/main/portage-ucp)
(for platform detection via `Resolver`) and
[`portage-ucp-client`](https://github.com/tomtom87/Portage/tree/main/portage-ucp-client)
(for the actual buy calls). No single adapter gem is a hard dependency — install
whichever `portage-ucp-<platform>` gem matches the store you're integrated with,
if any.

## Installation

```ruby
# Gemfile
gem "portage-cli"
```

```bash
bundle install
```

Or standalone:

```bash
gem install portage-cli
```

## Usage

```bash
portage buy <url> --query "..." [--qty N] [--payment-token TOKEN] [--product-id ID]
                                [--yes] [--dry-run] [--json]
portage buy --query "..." [--store URL] [--max-price N] [--limit N] ...
portage find --query "..." [--max-price N] [--limit N] [--json]
portage compare <url> --product-id ID [--id VALUE ...] [--results N]
                       [--max-price N] [--json]
portage history [list] [--purchases|--searches] [--limit N] [--json]
portage history clear [--purchases|--searches]
```

- `--query` — search term. Against the store's catalog when you name a store,
  against the search backends when you don't.
- `--qty` — quantity, default `1`.
- `--payment-token` — a tokenized payment credential (never a raw card number —
  `PaymentTokenGuard` in the core gem rejects those before they reach the wire).
  Omit for `--dry-run` or to just browse.
- `--product-id` — buy exactly this product rather than whatever the catalog
  search ranks first. If the id isn't in the results, nothing is bought.
- `--store` — name the merchant without giving a full URL; skips the search.
- `--max-price` — in major units (`400` means 400), compared per offer in that
  offer's own currency. No FX conversion.
- `--limit` — how many candidate stores to probe, capped at 12.
- `--yes` — skip the confirmation prompt before completing checkout.
- `--dry-run` — resolve and price the order without completing checkout.
- `--json` — machine-readable report instead of the human-readable summary.

Exits `0` when a checkout completed (or a dry-run/browse/search resolved
successfully), `1` otherwise — including the "no native manifest, no adapter
credentials" dead-end case, so it's scriptable in CI.

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

Every `find` (and `buy`, once it reaches a search) and every `buy` that
reaches checkout is logged locally to `~/.portage/history.json` — most recent
200 entries each, purchases and searches kept separately. Browse-only `buy`
reports (no checkout reached) aren't logged as purchases.

```bash
portage history                       # both lists, most recent last
portage history list --purchases      # just purchases
portage history list --searches --limit 20
portage history clear                 # wipe both
portage history clear --purchases     # wipe just one
```

This is a local convenience cache, not an audit log — `portage history clear`
deletes it outright, and there's no server-side record.

### Shipping address (own-store checkouts only)

When buying against your own store (`portage buy`'s step 2 adapter-credentials
fallback, described at the top of this file) and that adapter supports
`dev.ucp.shopping.fulfillment`, set a default shipping address via env
rather than a flag, same posture as adapter credentials:

```bash
export PORTAGE_SHIP_STREET="1 Main St"
export PORTAGE_SHIP_CITY="Erie"
export PORTAGE_SHIP_REGION="PA"          # optional
export PORTAGE_SHIP_COUNTRY="US"
export PORTAGE_SHIP_POSTAL_CODE="16501"
export PORTAGE_SHIP_FIRST_NAME="Ada"     # optional
export PORTAGE_SHIP_LAST_NAME="Lovelace" # optional
export PORTAGE_SHIP_PHONE="+1..."        # optional
```

`street`/`city`/`country`/`postal_code` are required — a partial profile is
treated as no profile at all. Once the merchant prices shipping options
against that address, `portage buy` auto-picks the cheapest per fulfillment
group; there's no interactive rate picker, since this drives one automated
purchase. Native (non-adapter) UCP stores don't get this yet — see
`portage-ucp`'s design log for why.

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
| Allowlist | `~/.portage/stores.yml` (YAML array of URLs) or `PORTAGE_STORES` (comma-separated) | Stores you already trust. Checked first, costs no network call. |
| DuckDuckGo | none | The [Instant Answer API](https://api.duckduckgo.com/api). Answers *entity* queries, not web queries: `burton snowboards` resolves to burton.com, `snowboard` resolves to nothing. |
| Brave | `BRAVE_SEARCH_API_KEY` | Real web results. Set this up if you want open-ended queries to work. |
| Google | `GOOGLE_CSE_KEY` + `GOOGLE_CSE_CX` | Programmable Search JSON API. |

Backends that have no credentials sit out; DuckDuckGo is the keyless default
because it's the only no-key engine with a real API, and its narrowness is the
price of not scraping.

## Development

```bash
bundle exec rspec
bundle exec rubocop
```

## License

[MIT](LICENSE) — Copyright (c) 2026 Tom Whitbread.
