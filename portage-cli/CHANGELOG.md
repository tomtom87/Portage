# Changelog

All notable changes to this project are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.0.0/); this project is
pre-1.0, so APIs may still shift between minor versions.

## [Unreleased]

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
