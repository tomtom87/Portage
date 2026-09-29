# CLI JSON reference

This page is the machine-readable contract of `portage` (gem `portage-cli` 0.8.0, plus the unreleased `pick`, `approve`, offer ref, quote and approval-policy changes described below) for agents and scripts that drive it with `--json`.

For flags and human-readable output, see the [CLI reference](../cli-reference.md). For how an agent loop uses these reports end to end, see [Agentic flow](../agentic-flow.md).

Source: `portage-cli/lib/portage/cli.rb`, `portage-cli/lib/portage/cli/*.rb`

## Conventions

- `--json` writes to stdout. Most commands print one pretty-printed JSON value. Some print an array, not an object (`doctor`, `orders reconcile`, `payment list`).
- `buy --wait --json` is the exception. It streams one-line JSON events first, then the final report. See [buy --wait](#buy-wait-ndjson-stream).
- Branch on `outcome` (buy) or on `error` (browser commands). Never branch on `message`.
- Money is an integer in minor units (cents, pence). `--max-price 400` means 400 major units and is converted to minor units by multiplying by 100. There is no currency conversion.
- Keys are always present unless the table says "omitted when empty". Unknown keys may be added in later versions.

### stderr

Diagnostics go to stderr, never into the JSON. Examples:

- `portage: ...` messages for a bad proxy config.
- The usage text.
- `portage: no buyer context set (...)` when no `PORTAGE_SHIP_*` / `PORTAGE_CURRENCY` / `PORTAGE_LANGUAGE` value is set.
- `portage: <url> serves a UCP manifest this client couldn't parse (...)`.
- `portage: couldn't open <url> (...)` when auto-open fails.

### Exit codes

| Command | Exit `0` | Exit `1` |
|---|---|---|
| `buy` | The report has `checkout: true` or `browse: true` | Both are false |
| `find`, `compare` | At least one offer | No offers |
| `pick`, `approve` | `picked`, `approved`, `viewed`, `needs_pick`, `needs_approval` | Any other outcome (`cancelled`, `search_not_found`, `offer_not_found`, `quote_not_found`, `quote_used`, `view_refused`, `no_terminal`, `invalid_option`, `error`) |
| `doctor`, `configure`, `setup` | No finding has `level: "warning"` | At least one warning |
| `policy set` | Applied | A lowering of `--require-approval` that wasn't confirmed at a terminal (nothing changed), or a usage error |
| `history`, `policy show`, `orders reconcile`, `index show`, `index sources`, `browser profile init/status` | Always | Not used |
| `payment list` | Always | Not used |
| `browser import` | No `error` key | `error` present |
| `browser profile open` | Attached | A `BrowserProfile` error |

A non-zero exit is not a failure of the tool. Read the JSON first.

For `buy`, the exit code follows the flags, not the `outcome`. Do not use it to detect a purchase.

- `purchased`, `dry_run`, `needs_confirmation`, `needs_approval`, `quote_changed`, `express_stop`, `requires_escalation`, `policy_blocked`, `low_confidence`, `checkout_mismatch`, `no_payment_token`, `permission_denied` exit `0`. So do `no_match`, `browse_only`, `store_refused` and `unsupported_wire_shape`.
- `handoff_only`, `dead_end`, `agent_profile_missing`, `request_rejected`, `adapter_misconfigured`, `adapter_error`, `webmcp_*`, `invalid_option`, and, from `buy --offer` and `buy --quote`, `offer_not_found`, `quote_not_found` and `quote_used` exit `1`.

Source: `cli.rb` (`execute_buy`, `buy_exit_code`, `print_prompt_result`, `run_find`, `report_doctor`, `report_browser_import`)

### Usage errors

`buy` turns a usage error into JSON. A bad `--qty`, `--min-confidence` or `--handoff-target` under `--json` prints this and exits `1`:

```json
{
  "url": null,
  "checkout_url": null,
  "products": [],
  "warnings": [],
  "source": "none",
  "outcome": "invalid_option",
  "browse": false,
  "checkout": false,
  "message": "invalid argument: --qty two"
}
```

`url` is the store URL if one was given, otherwise `null`. `pick` and `approve` under `--json` print a shorter one, `{ "outcome": "invalid_option", "message": "..." }` (a bad `--via` value, an unknown flag, or `approve` with no `QUOTE_ID`), and exit `1`. Every other command reports a usage error on stderr and exits `1`, with no JSON:

- A missing required argument prints the usage text.
- An unknown flag on `find`, `compare`, `doctor`, `history`, `orders`, `index show`, `payment` or `policy` raises an uncaught `OptionParser` exception (Ruby backtrace on stderr, exit `1`).
- `browser import` and `browser profile` catch it and print `<message>` plus the usage text to stderr.

`portage buy --json` with no URL and no query prints the usage text to stderr, not JSON.

Source: `cli.rb` (`invalid_buy_option`, `parse_buy_options`, `parse_find_options`, `run_browser_import`)

### Non-TTY behaviour

With no TTY on stdin nothing prompts on stdin. The commands that ask the person (`pick`, `approve`, and the numbered pick in `buy --query`) ask on `/dev/tty`, the controlling terminal, so they still reach a person when stdout is piped. Which one runs is set by `--via`, described under [Prompt surfaces](#prompt-surfaces).

- `buy` with no URL and no `--store` runs a `find`, prints the [find report](#find), and stops, unless there is a controlling terminal and no `--json`: then it asks the person to pick on that terminal. It exits `0` if there were offers, else `1`. `--yes` alone is not enough: a person or `--store` must name the merchant.
- `buy` with `--json` never prompts for WebMCP mapping or autofill confirmation.
- `setup` and `doctor` print the [doctor report](#doctor). The wizard only runs on a TTY without `--json`.
- `browser import` without `--yes` saves nothing and reports `needs_confirmation: true`.
- `pick` and `approve` with `--json` (and the default `--via auto`) ask nobody. They return `needs_pick` or `needs_approval` for the caller to show.
- Lowering `policy set --require-approval` needs a yes typed at a terminal. With none, it changes nothing, prints why on stderr and exits `1`.

Source: `cli.rb` (`buy_from_search`, `pick_offer`, `run_wizard?`, `run_browser_import`, `confirm_lowering`), `cli/human_prompt.rb`

### Prompt surfaces

`pick` and `approve` take `--via auto|tty|agent`:

| `--via` | Behaviour |
|---|---|
| `auto` (default) | `tty` if a controlling terminal can be opened and the run isn't `--json`, else `agent`. |
| `tty` | Asks the person on `/dev/tty`, even under `--json` (the answer is then printed as the JSON report). With no terminal it returns `no_terminal`, exit `1`. An answer typed here is recorded `by: "person"`. |
| `agent` | Asks nobody. Returns `needs_pick` or `needs_approval` with what to show. The caller relays the answer (`--choose`, `--relayed-yes`), recorded as `agent_relayed`. |

An agent should always pass `--json` and leave `--via` alone. Without `--json`, `auto` may try to ask on the user's own terminal. At a `tty` prompt, `v N` (pick) or `v` (approve) opens the product page and asks again; viewing is never an answer. A blank answer cancels.

Source: `cli/human_prompt.rb`

## find

`portage find --query "..." [--max-price N] [--limit N] --json`

Searches for stores that speak UCP, asks each what it stocks, and returns ranked offers. It never buys. It records a search in history.

Source: `cli/find.rb` (`report`, `offer`, `store_summaries`), `cli.rb` (`run_find`)

| Field | Type | Meaning |
|---|---|---|
| `query` | string | The search text. |
| `candidates` | array | Stores the search backends suggested. Each has `origin`, `source`, `handoff_only`. |
| `stores` | array | Candidates that were probed, plus hand-off-only ones. Each has `origin`, `source`, `checkout`, `handoff_only`. |
| `offers` | array | Ranked offers. Buyable first, then cheapest, then unpriced. |
| `message` | string or null | A summary, or the reason nothing was found. |
| `search_id` | string | Names the saved search (`se_` and 8 hex digits) for `pick --search`. Omitted when no offers were saved. |

`stores[].checkout` is `true` when the store advertises both cart and checkout. Hand-off-only hosts are listed with `checkout: false` and are never fetched.

Offer object:

| Field | Type | Meaning |
|---|---|---|
| `store` | string | Store origin, for example `https://www.burton.com`. |
| `offer_ref` | string | A short id (`of_` and 6 hex digits), saved with the search. Pass it to `buy --offer` and `pick --choose`. |
| `source` | string | Where the store came from: a search backend or offer source name (`duckduckgo`, `shopify_catalog`, ...). |
| `checkout` | boolean or null | `true`: buyable through UCP. `false`: browse or hand-off only. `null`: unknown (seen on `shopify_catalog` offers). |
| `product_id` | string | Pass this to `buy --product-id`. |
| `title` | string | Product title. |
| `amount` | integer or null | Price in minor units. `null` when unpriced. |
| `currency` | string or null | ISO currency code. |
| `url` | string or null | Product page. |

```json
{
  "query": "burton snowboards",
  "candidates": [
    { "origin": "https://www.burton.com", "source": "duckduckgo", "handoff_only": false }
  ],
  "stores": [
    { "origin": "https://www.burton.com", "source": "duckduckgo", "checkout": true, "handoff_only": false }
  ],
  "search_id": "se_3f9a1c22",
  "offers": [
    {
      "offer_ref": "of_a1b2c3",
      "store": "https://www.burton.com",
      "source": "duckduckgo",
      "checkout": true,
      "product_id": "gid://shopify/Product/9101005127937",
      "title": "Burton Cartographer Camber Snowboard",
      "amount": 52995,
      "currency": "USD",
      "url": "https://www.burton.com/en-us/products/burton-cartographer-camber-snowboard-2294212-o"
    }
  ],
  "message": "Found 10 offer(s) across 2 store(s)."
}
```

When nothing is found, `offers` is `[]` and `message` says why (no backend, no candidates, none speak UCP). If `PORTAGE_AGENT_PROFILE` is unset and a store needs it, `message` says to set it. An empty `--query` returns the same shape with `message: "Nothing to search for — pass --query."`.

`--max-price` drops offers priced above it, in each offer's own currency. Unpriced offers stay.

## buy

`portage buy <url> --query "..." [flags] --json`
`portage buy --offer REF [flags] --json`
`portage buy --quote QUOTE_ID --yes --json`

Every report is one object with an `outcome`. Only `purchased` means money moved.

- `--offer REF` takes the store, product and catalog query from the saved offer, as if you had passed them. An unknown ref returns `offer_not_found` (exit `1`).
- `--quote QUOTE_ID` buys what a `--dry-run` priced: the store, product, quantity and total come from the quote. See [quotes](#quotes).

Source: `cli/buy.rb` (`build_report`, `checkout_report`, `handoff_report`, `finalize_handoff`), `cli.rb` (`execute_buy`)

### Report fields

| Field | Type | Meaning |
|---|---|---|
| `url` | string | The store URL, with `https://` added if missing. |
| `outcome` | string | See [outcomes](#outcomes). |
| `message` | string | Human text. Do not parse it. |
| `source` | string | `native_ucp`, `webmcp`, `adapter:<Platform>`, `handoff_only`, or `none`. |
| `browse` | boolean | The store's catalog could be read. |
| `checkout` | boolean | A checkout path exists. |
| `checkout_url` | string or null | Where the shopper finishes. Always give it to the user when present. |
| `products` | array | Search results (catalog products as the store returned them). Not what is in the checkout. |
| `warnings` | array of strings | Where the checkout differs from the request. |

Checkout reports (those that created a checkout) add:

| Field | Type | Meaning |
|---|---|---|
| `checkout_id` | string | The store's checkout id. |
| `checkout_status` | string | The store's status, for example `requires_escalation`. |
| `currency` | string | Checkout currency. |
| `totals` | array | The store's totals lines (minor units). |
| `items` | array | What the checkout holds: `id`, `title`, `quantity`. |
| `handoff` | object or null | See [handoff](#handoff-object). `null` on `dry_run`. |
| `decisions` | object | See [decisions](#decisions). |
| `legal_notice` | string | Only on `handoff_only`. |
| `autofill` | object | Only on `express_stop` when WebMCP autofill ran: `outcome`, and when it filled, `filled`, `unmatched`, `rate`. |
| `would` | object | Only on a WebMCP `dry_run` against a preset that hands off through its own tool: `line_items`, `handoff_checkout`, `autofill`. |
| `tool_names_proposal` | object | Only on `webmcp_mapping_unconfirmed`. Maps a slot to `{tool_name, confidence, reason}`. |
| `reconcile` | object | Only with `--wait`. See [buy --wait](#buy-wait-ndjson-stream). |
| `quote_id` | string | On `dry_run` (and `needs_approval`, `quote_changed`): the saved [quote](#quotes). Omitted if it couldn't be saved. |
| `quoted_total`, `quoted_currency`, `current_total`, `current_currency` | integer, string | Only on `quote_changed`. Totals in minor units. |
| `summary` | object | Only on `needs_approval`. See [needs_approval](#needs_approval). |

### Outcomes

Only `purchased` means the order was placed.

| Outcome | Meaning | `checkout_url` |
|---|---|---|
| `purchased` | Order placed. | no |
| `dry_run` | Checkout priced, `--dry-run` stopped it. Nothing charged. | no |
| `needs_confirmation` | Checkout ready, `--yes` was not passed. | no |
| `needs_approval` | A real `--yes` run had no quote approved enough for [`require_approval`](#policy-set-require-approval). Nothing was bought or handed off. See [needs_approval](#needs_approval). | no |
| `quote_changed` | `--quote` run: the real checkout costs more than the quote (or is in another currency, or has no total). Nothing was bought or handed off, and the quote stays usable. | no |
| `offer_not_found` | `--offer REF` isn't a saved offer. | no |
| `quote_not_found` | `--quote` names no saved quote. | no |
| `quote_used` | The quote was already bought or handed off. | no |
| `express_stop` | WebMCP cart and checkout built. The store's own express-pay button finishes it. | yes |
| `requires_escalation` | The store needs a human step (verification, terms, 3-D Secure). | yes |
| `checkout_mismatch` | Checkout does not match the request. Only when `PORTAGE_ABORT_ON_CHECKOUT_MISMATCH` is on. Otherwise mismatches are only `warnings`. | yes |
| `no_payment_token` | No `--payment-token` and no default payment method. | yes |
| `permission_denied` | The store does not let this agent complete payment. | yes |
| `policy_blocked` | Your spend policy denied it. `decisions.policy.reason` says why. | yes |
| `low_confidence` | The confidence gate held it. | yes |
| `handoff_only` | Hand-off-only retailer (Amazon by default, plus Walmart, eBay, Best Buy, Etsy for buyers). No automation was attempted. | yes (built, never fetched) |
| `store_refused` | The store refused a cart or checkout call (for example sold out). | when the store gave one |
| `browse_only` | Catalog only, no UCP checkout. | when an adapter gives a link |
| `no_match` | Nothing matched the query, `--max-price`, or `--product-id`. | no |
| `dead_end` | No UCP, no WebMCP, no adapter. | no |
| `agent_profile_missing` | `PORTAGE_AGENT_PROFILE` is not set. | no |
| `request_rejected` | The store rejected the request. Often an agent profile it cannot fetch. | no |
| `unsupported_wire_shape` | The store speaks a UCP shape this version does not support. | no |
| `adapter_misconfigured` | Adapter credentials or config are wrong. | no |
| `adapter_error` | The adapter failed at run time. | no |
| `webmcp_not_installed` | A WebMCP bridge was attached but `portage-ucp-webmcp` is missing. | no |
| `webmcp_error` | The WebMCP checkout failed. | no |
| `webmcp_mapping_unconfirmed` | The page's tools need the user to approve a mapping. See `tool_names_proposal`. | no |
| `webmcp_token_unsupported` | `webmcp_checkout_mode=token` is set. Only `express_stop` is implemented. | no |
| `invalid_option` | A flag was refused before the buy started. | no |

Before any of the gates below, a real `--yes` run without an approved `--quote` is turned into a dry run and reported as `needs_approval` (unless `require_approval` is `off`). The quote's total is also a cap: `quote_changed` comes before every gate below.

The gates run in this order, and only on a real `--yes` run: escalation, then policy, then confidence. A `--dry-run` or a run without `--yes` only runs the escalation check, so `policy_blocked` and `low_confidence` cannot appear there.

### decisions

`decisions` holds one verdict per gate that ran. Every verdict has a `reason`: `null` when the gate let it through, otherwise a string.

```json
"decisions": {
  "escalation": { "escalate": false, "reason": null },
  "policy":     { "allowed": true, "reason": null },
  "confidence": { "proceed": false, "reason": "below_threshold", "confidence": 0.41,
                  "threshold": 0.8, "backend": "jev", "error": null }
}
```

| Gate | Fields | `reason` values |
|---|---|---|
| `escalation` | `escalate` (bool), `reason` | `requires_escalation` (the store's status), `mismatch` (warnings present and `PORTAGE_ABORT_ON_CHECKOUT_MISMATCH` on). |
| `policy` | `allowed` (bool), `reason` | `per_transaction_cap_exceeded`, `rolling_spend_cap_exceeded`, `velocity_exceeded`, `merchant_not_allowlisted`, `token_scope_merchant`, `token_scope_amount`, `currency_mismatch`, `total_unknown`. |
| `confidence` | `proceed`, `reason`, `confidence`, `threshold`, `backend`, `error` | `below_threshold`, `not_installed`, `backend_error`. Present only when a decision backend is set (`--decision-backend` or `PORTAGE_DECISION_BACKEND`). |

`total_unknown` means a spend cap exists and the checkout had no total. The policy check applies to native-UCP stores, WebMCP and adapter checkouts alike.

The `confidence` verdict also holds the purchase when the backend cannot answer (`not_installed`, `backend_error`). The default threshold is `0.8`.

Source: `cli/decisions.rb`, `cli/confidence_check.rb`, `portage-ucp/lib/portage/ucp/policy_guard.rb`, `portage-ucp/lib/portage/ucp/support/escalation.rb`

### handoff object

Present on hand-off outcomes when a `checkout_url` exists and it is not a `--dry-run`. Otherwise `null` or absent.

| Field | Type | Meaning |
|---|---|---|
| `url` | string | The checkout URL that was handed off. |
| `handoff_target` | string | `default`, `print`, `profile`, or `agent:<name>`. |
| `opened` | boolean | `default`: a browser was opened (needs auto-open on and an `https` URL). `profile`: the Portage profile was navigated. `print` and `agent`: always `false`. |
| `notified` | boolean | The `--notify-webhook` / `PORTAGE_NOTIFY_WEBHOOK_URL` POST succeeded. |
| `notify_error` | string or null | Why the webhook failed. |
| `agent_delivered` | boolean | Only for `agent:<name>`. The payload reached the approved agent. |
| `agent_error` | string or null | Only for `agent:<name>`. Why delivery failed, including "not approved in handoff_agents". |
| `target_message` | string | Only when `profile` could not attach. Says to run `portage browser profile open` first. |
| `over_cap` | boolean | Only `true`, and only with `PORTAGE_HANDOFF_SPEND_MODE=precheck` when the checkout is over a spend cap. Nothing was opened. |

The `handoff_only` outcome carries a `handoff` object too, except under `--dry-run` where it is `null`.

### Examples

A dry run:

```json
{
  "url": "https://shop.example.com",
  "checkout_url": null,
  "products": ["..."],
  "warnings": [],
  "source": "native_ucp",
  "outcome": "dry_run",
  "browse": true,
  "checkout": true,
  "message": "Dry run — checkout created but not completed.",
  "checkout_id": "chk_123",
  "checkout_status": "ready_for_complete",
  "currency": "USD",
  "totals": ["..."],
  "items": [{ "id": "var_1", "title": "Example board", "quantity": 1 }],
  "handoff": null,
  "decisions": { "escalation": { "escalate": false, "reason": null } }
}
```

A policy block:

```json
{
  "url": "https://shop.example.com",
  "checkout_url": "https://shop.example.com/checkouts/chk_123",
  "outcome": "policy_blocked",
  "source": "native_ucp",
  "browse": true,
  "checkout": true,
  "message": "Blocked by your spend policy (per_transaction_cap_exceeded) — not completed. ...",
  "handoff": {
    "url": "https://shop.example.com/checkouts/chk_123",
    "opened": false,
    "notified": false,
    "notify_error": null,
    "handoff_target": "print"
  },
  "decisions": {
    "escalation": { "escalate": false, "reason": null },
    "policy": { "allowed": false, "reason": "per_transaction_cap_exceeded" }
  }
}
```

Other fields (`products`, `warnings`, `checkout_id`, `totals`, `items`) are as in the table above.

### needs_approval

Returned by `buy` when a real run (`--yes`, no `--dry-run`) isn't approved enough, and by `approve` when the agent surface is used. Nothing is charged and nothing is handed off.

- `buy --yes` with no `--quote`: it ran as a dry run. The report is that dry run's (`checkout_id`, `totals`, `items`, and so on) with `outcome: "needs_approval"`, `quote_id` and `summary`. If it never got as far as a priced checkout (`no_match`, a dead end), it's reported as it is and has no `quote_id`.
- `buy --quote QUOTE_ID --yes` for a quote that isn't approved enough: no store call is made. The report is only `url`, `checkout_url: null`, `products: []`, `warnings: []`, `source: "none"`, `browse: false`, `checkout: false`, `outcome`, `quote_id`, `summary` and `message`. It exits `0`.

`summary`:

| Field | Type | Meaning |
|---|---|---|
| `quote_id` | string | The quote to approve, then buy. |
| `title` | string or null | What the checkout holds. |
| `store` | string | Store origin. |
| `product_id` | string | The product. |
| `qty` | integer | Quantity. |
| `total`, `currency` | integer or null, string | The total in minor units. |
| `total_display` | string | The total formatted for people, for example `24.00 USD`. `unknown` when there's no total. |
| `url` | string or null | The offer's product page, as `find` returned it. Show it as a link. |
| `approved_by` | string or null | `person` or `agent_relayed` when the quote is already approved. Under `require_approval: person`, `agent_relayed` isn't enough, and neither is null. |

```json
{
  "outcome": "needs_approval",
  "quote_id": "qt_5c0d1e2f3a4b",
  "summary": {
    "quote_id": "qt_5c0d1e2f3a4b",
    "title": "Cold Brew",
    "store": "https://shop.example",
    "product_id": "p1",
    "qty": 2,
    "total": 2400,
    "currency": "USD",
    "total_display": "24.00 USD",
    "url": "https://shop.example/products/cold",
    "approved_by": null
  },
  "message": "Nothing was bought. Quote qt_5c0d1e2f3a4b (2 × Cold Brew from https://shop.example for 24.00 USD) needs approval first (require_approval: any). Approve it with `portage approve qt_5c0d1e2f3a4b`, then run `portage buy --quote qt_5c0d1e2f3a4b --yes`."
}
```

(Trimmed: a `buy` report also carries the fields above.)

### quotes

A `--dry-run` that priced a checkout saves a quote to `~/.portage/quotes/QUOTE_ID.json` and reports its `quote_id` (`qt_` and 12 hex digits). `buy --quote QUOTE_ID --yes` buys exactly it: the real run is capped at the quoted total and currency, and refuses with `quote_changed` if the checkout costs more. Quotes never expire. Each is used once: it is spent by a `purchased` outcome or any hand-off. A `quote_changed`, `needs_approval` or error leaves it usable.

The file's fields (the format is private and may change): `quote_id`, `offer_ref`, `store`, `product_id`, `query`, `qty`, `total`, `currency`, `title`, `url`, `created_at`, `approved` (boolean), and, once approved, `approved_by` (`person` or `agent_relayed`) and `approved_at`; and `used_at` once spent. A relayed yes never downgrades a quote the person already approved.

### Recording

A buy that created a checkout is written to history as a purchase, whatever its outcome. One that never got that far is written as a search. History entries are covered under [history](#history).

### buy --wait (NDJSON stream)

`--wait` polls the store after a hand-off until the checkout settles, times out or is interrupted. Under `--json` the stdout is not one object. It is:

1. One compact line per event, as it happens.
2. The final pretty-printed report, with an added `reconcile` object.

Nothing is waited on for `--dry-run`, or when the report has no `handoff` and `checkout_id`, or has no pending record. In that case there are no event lines and no `reconcile` key.

| `event` | Fields |
|---|---|
| `handoff` | `checkout_id`, `checkout_url`, `reason` (the report's outcome) |
| `handoff_status` | `status` (the store's checkout status, on each change) |
| `handoff_settled` | `result` (`complete` or `failed`), `resolution`, `order_id`, `amount`, `currency` (nulls omitted) |

`reconcile` has the same shape as one item of [orders reconcile](#orders-reconcile). A timeout or Ctrl-C leaves `settled: false` and `note: "wait interrupted"` (for Ctrl-C). `--wait-timeout` takes seconds, `30s`, `5m`, `2h`, or `off`. The default is 30 minutes, capped by the checkout's own `expires_at`.

Source: `cli.rb` (`wait_for_handoff`, `emit_wait_event`), `cli/handoff_waiter.rb`, `cli/handoff_wait_timeout.rb`

## compare

`portage compare <url> --product-id ID [--id VALUE ...] [--results N] [--max-price N] --json`

Finds the same product at other stores. It returns the [find report](#find) shape. Offers are re-ranked by match tier, then buyable, then price, and the origin store is excluded.

Source: `cli/compare.rb`

The report also carries a `search_id`, and its offers carry `offer_ref`, so a compare's offers can be picked or bought like `find`'s. Each offer has the [find offer fields](#find) plus:

| Field | Type | Meaning |
|---|---|---|
| `match` | string | `confirmed` (shared barcode), `likely` (shared SKU or an `--id` hit), `unconfirmed` (matched the title search only). |
| `identity_values` | object | `barcodes` (array) and `sku` (string or null) of the candidate. |
| `store_host` | string | The candidate store's host. |

Prices are catalog prices, not landed prices. `--results` limits how many offers are kept (default 5). If the origin cannot be resolved (not a store URL, hand-off only, no UCP, product not found) the report has empty `candidates`, `stores` and `offers`, and `message` says why. It exits `1`.

## pick

`portage pick [--search LAST|SEARCH_ID] [--via auto|tty|agent] [--choose REF | --compare REF | --view REF] --json`

Loop step 3: the person picks the store from a saved search's offers. `--search` defaults to `LAST`, the latest search that kept offers. Not a purchase, so nothing is bought. See [Prompt surfaces](#prompt-surfaces) for `--via`.

Source: `cli/pick.rb`, `cli/offer_choice.rb`, `cli.rb` (`run_pick`)

| Call | Result |
|---|---|
| `pick --json` | `needs_pick`. |
| `pick --choose REF --json` | `picked`, `by: "agent_relayed"`. |
| `pick --compare REF --json` | Compares offer `REF` across stores, then `needs_pick` over the results. |
| `pick --view REF --json` | `viewed`, or `view_refused`. |
| `pick --via tty` (or `auto` without `--json`, at a terminal) | Asks the person; `picked` with `by: "person"`, or `cancelled`. |

`needs_pick`:

| Field | Type | Meaning |
|---|---|---|
| `outcome` | string | `needs_pick`. |
| `search_id`, `query` | string | The search the choices come from. After `--compare`, the new search that holds the compare's offers. |
| `choices` | array | The offers, then one more choice, `compare`. |
| `message` | string | Human text with the relay commands. |

Each `choices[]` entry:

| Field | Type | Meaning |
|---|---|---|
| `ref` | string | The `offer_ref`, or `compare` for the last choice. Pass it to `--choose` (or `--compare`). |
| `label` | string | Ready to show: store, title and price, plus `browse only` when `checkout` is `false`. |
| `url` | string or null | The offer's product page as `find` returned it. Show it as a link. `null` for `compare`. |
| `store`, `product_id`, `title`, `amount`, `currency`, `checkout` | varies | The offer's own fields. Not present on the `compare` choice. |
| `relay` | string | Only on `compare`: the command that runs it. |

`picked` carries `search_id`, `offer_ref`, `store`, `product_id`, `title`, `url`, `by` (`person` or `agent_relayed`) and a `message` naming the next step, `portage buy --offer REF --dry-run`.

`--compare REF` runs the same compare `portage compare` does, from that offer's store and product. It saves the compare as a search of its own, the compared offer first, so `--choose` and `buy --offer` resolve its refs; pass the returned `search_id` (or rely on `LAST`). With no results the report is the old search's `needs_pick`, and `message` says nothing was found. Compare uses the proxy settings from env and `config.json`. `pick` has no `--proxy` flags.

`--view REF` opens the offer's product page in the browser and does nothing else: it is never a pick. It only opens an `http(s)` URL on the offer's own store host (compared without a leading `www.`), with no credentials in it. Anything else gives `view_refused` and opens nothing, since store data is untrusted. `viewed` carries `offer_ref`, `url`, `opened` (whether a browser could be opened) and `message`. `view_refused` carries `offer_ref` (from `pick`), `url`, `store` and the reason as `message`.

Other outcomes: `cancelled` (a blank answer at a terminal), `search_not_found` (no saved search, or no such `--search`), `offer_not_found` (`REF` isn't one of the search's offers, or for `--view`, isn't saved), `no_terminal`.

```json
{
  "outcome": "needs_pick",
  "search_id": "se_3f9a1c22",
  "query": "cold brew",
  "choices": [
    {
      "ref": "of_a1b2c3",
      "label": "https://shop.example — Cold Brew — 24.00 USD",
      "store": "https://shop.example",
      "product_id": "p1",
      "title": "Cold Brew",
      "amount": 2400,
      "currency": "USD",
      "checkout": true,
      "url": "https://shop.example/products/cold"
    },
    {
      "ref": "compare",
      "label": "Compare an offer across stores",
      "url": null,
      "relay": "portage pick --search se_3f9a1c22 --compare REF"
    }
  ],
  "message": "Show these choices to the person (with each url as a link), then relay their answer: ..."
}
```

## approve

`portage approve QUOTE_ID [--via auto|tty|agent] [--relayed-yes | --view] --json`

Loop step 5: the person says yes to a quote's exact total. Not a purchase. It never charges. See [Prompt surfaces](#prompt-surfaces) for `--via`. `QUOTE_ID` comes first.

Source: `cli/approve.rb`, `cli.rb` (`run_approve`)

| Call | Result |
|---|---|
| `approve QUOTE_ID --json` | `needs_approval` with `summary`. |
| `approve QUOTE_ID --relayed-yes --json` | `approved`, `approved_by: "agent_relayed"`. Under `require_approval: person` it isn't recorded: the result is `needs_approval` telling the agent to ask the person to run `portage approve QUOTE_ID` themselves. |
| `approve QUOTE_ID --view --json` | `viewed`, or `view_refused`. Never an approval. |
| `approve QUOTE_ID` at a terminal | Shows title, store, quantity and total, asks yes/no (`v` opens the page). A yes gives `approved`, `approved_by: "person"`. Anything else gives `cancelled`. |

`needs_approval` is described under [buy](#needs_approval). `approved` carries `quote_id`, `approved_by`, `summary` and a `message` naming the next step, `portage buy --quote QUOTE_ID --yes`. `viewed` carries `quote_id`, `url`, `opened` and `message`, with the same host rule as `pick --view`; `view_refused` carries `quote_id`, `url`, `store` and `message`.

Other outcomes: `quote_not_found`, `quote_used` (the quote was already bought or handed off), `cancelled`, `no_terminal`, and `error` (the approval couldn't be saved).

Whether an approval is enough to buy is the [approval policy's](#policy-set-require-approval) call, made when `buy --quote --yes` runs.

## history

`portage history [list] [--purchases|--searches] [--limit N] --json`

```json
{
  "purchases": [],
  "searches": [
    {
      "query": "burton snowboards",
      "url": "https://www.burton.com",
      "offer_count": 10,
      "message": "No product matched \"burton snowboards\" at or under 10000 minor units.",
      "at": 1790242494
    }
  ]
}
```

Source: `cli/history.rb`, `cli.rb` (`run_history_list`)

Purchase entry:

| Field | Type | Meaning |
|---|---|---|
| `url` | string | The store. |
| `query` | string | The search text. |
| `outcome` | string | The buy report's outcome. Entries from older versions have none. |
| `source` | string | The report's `source`. |
| `checkout_id`, `checkout_status`, `checkout_url` | string or null | The checkout. |
| `total` | integer or null | Minor units of `currency`. |
| `currency` | string or null | Currency. |
| `items` | array | `id`, `title`, `quantity`. |
| `message` | string | Report message. |
| `at` | integer | Unix time. |

Search entry: `query`, `url` (omitted for a cross-store `find`), `offer_count`, `message`, `at`. A search that kept offers also has `search_id` and `offers[]` (`offer_ref`, `store`, `product_id`, `title`, `amount`, `currency`, `url`, `checkout`, `found_at`, and `query` for a compare's offers). `compare` also records a search, with a `query` starting `compare:`.

"What did I buy" is the purchases whose `outcome` is `purchased`. Every other purchase still carries the `checkout_url`. A `buy` that ends in `no_match`, `browse_only`, `dead_end` or a store error has no checkout, so it is a search entry with no `outcome`. Both lists are capped at 200 entries. `history clear` prints text, not JSON.

## orders reconcile

`portage orders reconcile [--checkout ID] --json`

Prints an array, one item per pending hand-off record (or the one named by `--checkout`). It is safe to run from cron. It always exits `0`. An empty array means nothing to reconcile, or an unknown `--checkout`.

Source: `cli.rb` (`run_orders_reconcile`), `cli/handoff_reconciler.rb` (`Result#to_h`)

| Field | Type | Meaning |
|---|---|---|
| `idempotency_key` | string | The record's key, `portage-buy:<host>:<checkout id>`. |
| `settled` | boolean | The record moved to a final state in this run. |
| `status` | string | `complete`, `failed` or `pending`. |
| `resolution` | string | On `failed`: `expired`, `unknown`, or omitted when the store canceled. |
| `order_id` | string | The store's order id, when known. |
| `amount` | integer | Minor units, on `complete`. |
| `currency` | string | Currency, on `complete`. |
| `checkout_status` | string | The store's current status, while `pending`. |
| `note` | string | For example `already settled`, `not a shopper handoff`, or the reconnect error. |

Keys with no value are omitted.

```json
[
  {
    "idempotency_key": "portage-buy:shop.example.com:chk_123",
    "settled": true,
    "status": "complete",
    "order_id": "ord_456",
    "amount": 52995,
    "currency": "USD"
  }
]
```

## policy show

`portage policy show --json` prints the contents of `~/.portage/policy.json`, with `require_approval` always added at its effective value. It exits `0`.

Source: `cli.rb` (`run_policy_show`), `cli/approval_policy.rb`, `portage-ucp/lib/portage/ucp/policy.rb`

| Key | Shape |
|---|---|
| `per_transaction_cap` | `{ "amount": int, "currency": "USD" }` |
| `rolling_cap` | `{ "amount": int, "currency": "USD", "window_seconds": int }` |
| `velocity` | `{ "count": int, "window_seconds": int }` |
| `merchant_allowlist` | array of hosts |
| `token_scopes` | object keyed by token reference. Each has `merchants`, `max_amount`, `currency` as set at enrol time. |
| `require_approval` | `any`, `person` or `off`. Always present: `any` when never set. |

The other keys appear only when they were set. With nothing set the output is `{ "require_approval": "any" }`. In text, `policy show` ends with `require_approval: any (default)`.

## policy set --require-approval

`portage policy set --require-approval person|any|off`

What a real `buy --yes` needs before it may charge or hand off. Default `any`. Stored as `require_approval` in `~/.portage/policy.json`, next to the caps. There is deliberately no env var or `config.json` override.

| Level | A real `buy --yes` buys when |
|---|---|
| `off` | Always: `--yes` alone, as before this setting existed. |
| `any` | It runs `--quote QUOTE_ID` for a quote approved by the person (`approved_by: "person"`) or relayed by an agent (`agent_relayed`). |
| `person` | It runs `--quote QUOTE_ID` for a quote the person approved at a terminal. A relayed yes doesn't count. |

Otherwise the run is refused with [`needs_approval`](#needs_approval) and a `quote_id`, and never charges or hands off. A `--dry-run` is never gated. An unrecognised stored value is treated as `person`.

Raising the level (or setting the same one) needs nothing. Lowering it (`person` to `any` or `off`, `any` to `off`) needs a yes typed on the terminal, so an agent that can run `policy set` can't lower it. With no terminal it changes nothing, prints why on stderr and exits `1`. A refused lowering also leaves every other flag in the same `policy set` call unapplied.

!!! warning "Upgrade note"
    Under the default `any`, a `buy --yes` without an approved `--quote` no longer buys. It dry-runs and returns `needs_approval`. To restore the old behaviour, run `portage policy set --require-approval off` from a terminal.

!!! note "Limits"
    `person` raises the bar but isn't a hard guarantee. A model can't type on `/dev/tty`, but an agent with a shell can edit `~/.portage/policy.json` or the quote files under `~/.portage/quotes/` directly, or make a terminal of its own (`script`, `expect`). The gate lives in the CLI (`portage buy`), not in `portage-ucp`, so a program that calls the Ruby library directly isn't governed by it. Use `person` for an agent running from your own terminal, and keep the approval in your own code for anything else.

Other keys' `policy set` output is unchanged: it prints the resulting policy as text (or `(no policy configured — every spending check passes)`), not `--json`.

## payment list

`portage payment list --json` prints an array of enrolled methods. Tokens are never included. It is `[]` when nothing is enrolled, and always `[]` in headless mode (see `PORTAGE_PAYMENT_TOKEN` below).

Source: `cli/payment_methods.rb`

| Field | Type | Meaning |
|---|---|---|
| `id` | string | UUID. Use with `set-default`, `remove`, `freeze`, `revoke`. |
| `label` | string | The `--label`, or the id. |
| `default` | boolean | Used when `buy` has no `--payment-token`. |
| `frozen` | boolean | A frozen default is never used. |
| `created_at` | string | ISO 8601 UTC. |

`portage payment enroll --json` prints an object with a `status`: `complete` (with `id`, `label`), `pending` (with `setup_url`, `id`), `handoff_only` (with `host`) or `unsupported`. It exits `0` only on `complete`.

## doctor

`portage doctor --json` (also `configure`, and `setup` with `--json` or no TTY) prints an array of findings. It exits `1` if any finding has `level: "warning"`.

Source: `cli/doctor.rb` (`Finding`, `call`), `cli.rb` (`report_doctor`), `cli/install_doctor.rb`, `cli/proxy_doctor.rb`

| Field | Type | Meaning |
|---|---|---|
| `check` | string | The check name. |
| `message` | string | Human text. |
| `level` | string | `warning` or `info`. Only warnings affect the exit code. |
| `details` | object | Structured data for some checks. Omitted otherwise. |

Check names seen in a default run: `install`, `runtime`, `adapters`, `path`, `env_file`, `seller`, `agent_profile`, `index`, `handoff`, `retailer_offer_sources`. Warnings can also come from `authenticator`, `rate_limiter`, `signing_keys`, `payment_handlers`, `decision_backend`, `user_agent`, `shipping`, `proxy`, `proxy_routes`, `proxy_reachability`, `proxy_credentials`, `proxy_payment_intercept` and `capability:<name>`. `search_backend` is `info`.

The seller checks (`authenticator`, `rate_limiter`, `signing_keys`, `payment_handlers`) only run with `--require` or `--adapter`. Without them a `seller` info finding says they were skipped.

```json
[
  {
    "check": "runtime",
    "message": "Ruby 4.0.7 (/opt/homebrew/Cellar/ruby/4.0.7/bin/ruby), portage-cli 0.8.0",
    "level": "info",
    "details": {
      "ruby_version": "4.0.7",
      "ruby_path": "/opt/homebrew/Cellar/ruby/4.0.7/bin/ruby",
      "portage_cli_version": "0.8.0"
    }
  },
  {
    "check": "handoff",
    "message": "Hand-off target: default. Hand-off-only hosts (22): amazon.com, ...",
    "level": "info",
    "details": { "target": "default", "handoff_only_hosts": ["amazon.com", "..."] }
  }
]
```

## index show

`portage index show [--stores|--products] --json` prints two arrays. The one you did not ask for is `[]`.

```json
{ "stores": [], "products": [] }
```

Source: `cli.rb` (`run_index_show`), `cli/index/store.rb`

Store entries are the records in `~/.portage/index/stores.json`. Each has an `origin`, plus fields such as `sources`, `last_verified`, `capabilities`, `categories` and `handoff_only`. Product entries are the records in `~/.portage/index/products.json`. Treat any field beyond `origin` and `title` as optional.

`index add` and `index remove` with `--json` print `{ "added": bool, "origin": ..., "message": ... }` and `{ "removed": bool, "message": ... }`. They exit `0` on success and `1` otherwise.

## browser import

`portage browser import [flags] --json` reads browser history and bookmarks, reduces them to shop domains and probes unknown ones. It writes nothing unless `--yes` is passed (or a person confirms at a TTY without `--json`). It is not a purchase, so there is no `outcome`.

Source: `cli.rb` (`run_browser_import`, `report_browser_import`), `cli/browser_import/importer.rb`, `cli/browser_import/confirm.rb`

### Top-level fields

| Field | Type | Meaning |
|---|---|---|
| `browser` | string | The browser read. |
| `profiles` | integer | Profiles found. |
| `files_opened` | array | Files read. |
| `rows` | object | `history` and `bookmark` row counts. |
| `domains` | integer | Distinct domains. |
| `skipped` | object | Reason to count. |
| `already_indexed`, `known` | integer | Counts by verdict. |
| `probed`, `cached_miss`, `not_ucp`, `unprobed` | integer | Probe counts. |
| `capped` | boolean | The probe cap (`--max-probes`) was hit. |
| `kept` | array | Shops found. See below. |
| `products` | array | Product pages, only with `--include-product-pages`. |
| `saved` | boolean | Written to the local index. |
| `needs_confirmation` | boolean | Found shops but wrote nothing because nobody confirmed. |
| `message` | string | Human text. |

`kept[]` entry:

| Field | Type | Meaning |
|---|---|---|
| `domain` | string | Normalised host. |
| `origin` | string | Store origin. |
| `verdict` | string | `ucp` (answered `/.well-known/ucp`), `indexed` (already in your index), `known` (in the published known-stores list), or `handoff_only`. |
| `sources` | array | `history`, `bookmark`. |
| `visits` | integer | Visit count. |
| `categories` | object | Category scores. |
| `category_names` | array | Category names. Empty means the store is only used when the user names it. |
| `capabilities`, `last_verified`, `handoff_only` | varies | Present when the verdict supplies them. |

### Outcomes by field

| State | Meaning |
|---|---|
| `saved: false`, `needs_confirmation: true` | Found shops, nothing written (no TTY, no `--yes`). Show `kept[]`, then re-run with `--yes` after the user approves. `--exclude host,host` drops entries. |
| `saved: false`, `needs_confirmation: false` | `--dry-run`, nothing to save, or a declined prompt. |
| `saved: true` | Written. `message` says how many stores and products. |

Exit `0` for all three. When `error` is present the exit is `1`. Error values:

| `error` | Meaning |
|---|---|
| `full_disk_access_required` | Safari: macOS needs Full Disk Access for the terminal. |
| `permission_denied` | Another browser's profile folder could not be read. |
| `no_profile` | No profile with history or bookmarks was found for that browser or `--profile-root`. |
| `reader_unavailable` | The `sqlite3` command is missing or failed. `message` names the cause. |

An error report is `{ "browser": ..., "error": ..., "message": ..., "saved": false, "needs_confirmation": false }`. Relay `message`. Do not work around a permission error.

```json
{
  "browser": "chrome",
  "profiles": 1,
  "rows": { "history": 812, "bookmark": 40 },
  "domains": 120,
  "skipped": { "excluded": 1 },
  "probed": 14,
  "capped": false,
  "kept": [
    {
      "domain": "shop.example.com",
      "origin": "https://shop.example.com",
      "verdict": "ucp",
      "sources": ["history"],
      "visits": 7,
      "category_names": ["Outdoor"]
    }
  ],
  "products": [],
  "saved": false,
  "needs_confirmation": true,
  "message": "Nothing saved: there's no terminal to confirm on. ..."
}
```

(Example trimmed and illustrative. Some fields are omitted.)

## browser profile

`portage browser profile init|status|open [--browser chrome|edge|brave|arc] [--port N] [--url URL] --json`

This is a dedicated Chromium-family profile under `~/.portage/browser/`, never the browser's default profile. It is not a purchase, so there is no `outcome`. The default port is `9223`.

Source: `cli.rb` (`run_browser_profile_*`), `cli/browser_profile/profile.rb`, `cli/browser_profile/errors.rb`

| Subcommand | Output |
|---|---|
| `init` | `{ browser, dir, port, created: true }`. Creates the directory if needed. |
| `status` | `{ running, browser, dir, port }`. When `running` is `true`, the fields of the browser's own `/json/version` are merged in. Exits `0` either way. |
| `open` | `{ running: true, browser, dir, port, target }`. `target` is the attached tab's CDP object, or `null`. |

`open` under `--json` reports a failure as `{ "error": "<ErrorClass>", "message": ... }` and exits `1`:

| `error` | Meaning |
|---|---|
| `BrowserNotFoundError` | The requested (or auto-detected) browser is not installed. |
| `LaunchError` | The browser started but did not answer its debugging port in time. |

```json
{
  "running": false,
  "browser": "chrome",
  "dir": "/Users/example/.portage/browser/chrome/profile",
  "port": 9223
}
```

Run `open` before `buy --handoff-target profile`.

## Environment variables

Only variables read by `portage-cli` are listed. `~/.portage/.env` (or the file named by `PORTAGE_ENV_FILE`) is loaded at start-up. It never overrides a variable already set in the real environment.

Source: `portage-cli/exe/portage`, `cli/dot_env.rb`, `cli/setting.rb`

| Variable | Effect |
|---|---|
| `PORTAGE_ENV_FILE` | Path of the env file to load instead of `~/.portage/.env`. |
| `PORTAGE_HANDOFF_TARGET` | Default `--handoff-target`: `default`, `print`, `profile`, or `agent:<name>`. An unknown value is a usage error (`invalid_option`). |
| `PORTAGE_AUTO_OPEN_CHECKOUT` | `1`, `true` or `yes` opens `https` checkout URLs in the default browser. Overridden by `--auto-open` / `--no-auto-open`. |
| `PORTAGE_NOTIFY_WEBHOOK_URL` | Webhook POSTed on each hand-off. Overridden by `--notify-webhook`. |
| `PORTAGE_PAYMENT_TOKEN` | Headless payment token. When the OS keychain or secret service is unavailable, this is the only source, and `payment list` returns `[]`. |
| `PORTAGE_AGENT_PROFILE` | URL of your agent profile. Stores verify it before answering. Without it, `agent_profile_missing` or a fallback to the repo's published profile (see `doctor`). |
| `PORTAGE_DECISION_BACKEND` | Names the confidence-gate backend. Overridden by `--decision-backend`. |
| `PORTAGE_MIN_CONFIDENCE` | Gate threshold, `0.0` to `1.0`. Read only while a backend is set. Overridden by `--min-confidence`. |
| `PORTAGE_ABORT_ON_CHECKOUT_MISMATCH` | When on, a mismatch becomes the `checkout_mismatch` outcome. |
| `PORTAGE_HANDOFF_SPEND_MODE` | `block` (default), `warn` or `precheck`. |
| `PORTAGE_HANDOFF_WAIT_TIMEOUT` | Default for `--wait-timeout`. |
| `PORTAGE_RECONCILE_NOTIFY` | Channels for reconcile notifications. |
| `PORTAGE_WEBMCP_CHECKOUT_MODE` | `express_stop` (default) or `token` (gives `webmcp_token_unsupported`). |
| `PORTAGE_WEBMCP_AUTOFILL` | `approve` turns autofill on (a per-run prompt still applies). |
| `PORTAGE_SHIP_COUNTRY`, `PORTAGE_SHIP_REGION`, `PORTAGE_SHIP_POSTAL_CODE`, `PORTAGE_CURRENCY`, `PORTAGE_LANGUAGE` | Buyer context sent with catalog and checkout calls. Set at least `PORTAGE_SHIP_COUNTRY`. |
| `PORTAGE_SHIP_STREET`, `PORTAGE_SHIP_EXTENDED`, `PORTAGE_SHIP_CITY`, `PORTAGE_SHIP_FIRST_NAME`, `PORTAGE_SHIP_LAST_NAME`, `PORTAGE_SHIP_PHONE` | With street, city, country and postal code, a full shipping address. A partial address counts as none. |
| `PORTAGE_USER_AGENT` | Outbound `User-Agent`. A value with a newline is a `doctor` warning. |
| `PORTAGE_STORES` | Comma-separated extra stores for `find`. |
| `BRAVE_SEARCH_API_KEY`, `GOOGLE_CSE_KEY` + `GOOGLE_CSE_CX` | Real web search for `find` and `buy` without a URL. |
| `PORTAGE_PROXY`, `PORTAGE_PROXY_MODE`, `PORTAGE_PROXY_HEADERS`, `PORTAGE_NO_PROXY`, `PORTAGE_PROXY_CA` | Proxy settings. See the [CLI reference](../cli-reference.md). |

Each of the handoff, notify, wait, reconcile and WebMCP settings also has a `~/.portage/config.json` key. The order is flag, then env var, then config.
