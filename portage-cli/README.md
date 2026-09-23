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
(for platform detection via `Resolver`),
[`portage-ucp-client`](https://github.com/tomtom87/Portage/tree/main/portage-ucp-client)
(for the actual buy calls), and
[`portage-ucp-journal`](https://github.com/tomtom87/Portage/tree/main/portage-ucp-journal)
(for `portage-console`'s read-only view of local purchase state — see below).
No single adapter gem is a hard dependency — install whichever
`portage-ucp-<platform>` gem matches the store you're integrated with, if any.

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
                                [--yes] [--dry-run] [--decision-backend jev|laya]
                                [--min-confidence N] [--json]
portage buy --query "..." [--store URL] [--max-price N] [--limit N] ...
portage find --query "..." [--max-price N] [--limit N] [--json]
portage compare <url> --product-id ID [--id VALUE ...] [--results N]
                       [--max-price N] [--json]
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
```

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
  offer's own currency. No FX conversion.
- `--limit` — how many candidate stores to probe, capped at 12.
- `--yes` — skip the confirmation prompt before completing checkout.
- `--dry-run` — resolve and price the order without completing checkout.
- `--decision-backend` — opt into the confidence gate (see "Decisions" below):
  `jev` or `laya`. Defaults to `PORTAGE_DECISION_BACKEND`; unset means off.
- `--min-confidence` — the gate's threshold, `0.0`–`1.0`. Defaults to
  `PORTAGE_MIN_CONFIDENCE`, then `0.8`.
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

### Decisions

`portage buy` and `portage find` make their judgment calls through
`portage-ucp-decision` (`docs/plans/system-one-decision-layer.md`) when it's
installed. It's an optional plugin, not a dependency:

```bash
gem install portage-ucp-decision   # only needed for the confidence gate
```

Without it, built-in fallbacks give the same ranking, escalation and policy
answers, and the policy check still runs (it needs only `portage-ucp`). The
confidence gate is the one feature that needs the gem. Every checkout report
carries the verdicts under `decisions:`, so a script or agent loop can branch
on data rather than on the message text:

```json
"decisions": {
  "escalation": { "escalate": false, "reason": null },
  "policy":     { "allowed": false, "reason": "per_transaction_cap_exceeded" },
  "confidence": { "proceed": true, "confidence": 0.93, "threshold": 0.8, "backend": "jev" }
}
```

- **escalation** — `EscalationPolicy`. A `requires_escalation` checkout always
  escalates. A checkout that doesn't match the request escalates only under
  `PORTAGE_ABORT_ON_CHECKOUT_MISMATCH`; otherwise it's reported as `warnings`.
- **policy** — `PolicyCheck`, run on your policy file (see "Policy" above)
  before any `--yes` completion. It applies to remote native-UCP stores too.
  Before this check, only the own-store adapter flow's in-process
  `Dispatcher` enforced the policy. Rolling caps and velocity limits count
  only what the transaction log holds, and only own-store purchases write to
  that log.
- **confidence** — `ConfidenceGate`, off unless `--decision-backend` or
  `PORTAGE_DECISION_BACKEND` names a backend. Right before a `--yes`
  completion it asks the backend whether the checkout matches the request
  and is safe to complete unattended. It sends the query, merchant,
  quantity, line items, totals and warnings, never the payment token. A
  score below the threshold holds the purchase. So does a backend that can't
  answer, or naming a backend without `portage-ucp-decision` installed,
  because the gate fails closed. `jev` needs `JEV_API_KEY`; `laya`
  needs `LAYA_BRIDGE_SCRIPT` (see `portage-ucp-decision`'s README).

A blocked or held purchase hands the checkout off the same way an escalation
does (`checkout_url`, plus `--auto-open`/`--notify-webhook` if set). The
shopper can finish it themselves. `portage find`'s offer order comes from
`OfferRanking`: buyable first, then cheapest, then unpriced.

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
