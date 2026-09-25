# Changelog

All notable changes to this project are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.0.0/); this project is
pre-1.0, so APIs may still shift between minor versions.

## [0.10.0] - 2026-09-25

- **Proxy support** (`docs/plans/proxy-support.md` Phases 1 and 3).
  `Support::Connection.start(uri, route:, proxy: ProxyConfig.current, ...)`
  replaces every raw `Net::HTTP.start` call site. It resolves
  `HTTPS_PROXY`/`https_proxy` for https targets (Net::HTTP's own `:ENV`
  mode never read them) and honors `NO_PROXY`. It also supports
  `ProxyConfig` routes and named chains: `:forward` proxies (natively, or
  through a hand-rolled CONNECT tunnel when `proxy_headers` are set or
  hops are chained), `:gateway` mode, `ca_file` and timeout overrides.
  A hop failure raises `Portage::Ucp::ProxyError` naming the hop and the
  redacted proxy host. `ProxyConfig::Profile` refuses `Authorization`,
  `User-Agent`, `X-Shopify-*-Access-Token` and `X-Payment-Token` in
  proxy/forward headers. `Support::HttpClient#json_request` takes
  `route:` (default `:platform`); `Check` uses `:probe` and
  `Support::TokenExchange` uses `:payment`.
- `Rack::ForwardedRequest`, a fail-closed helper that trusts
  `X-Forwarded-*`/`Forwarded` only from a configured `trusted_proxies`
  list, resolves the right-most untrusted hop as the client IP, and lets
  `X-Forwarded-Host` replace an endpoint's origin only for a trusted peer
  and an allowlisted host. `Rack::WebhookEndpoint` uses it.
- `Support::PassthroughContext`, a fiber-local scope that carries an
  inbound request's allowlisted, trusted-peer-only headers and
  `Forwarded`/`X-Forwarded-For` chain onto the outbound
  `Support::Connection` calls made while serving it.
- Adapter and CLI gems that call `Support::Connection` need `~> 0.10`.

- `Support::TransactionLog#reserve`/`#complete` accept a fixed allowlist of
  optional attributes (`OPTIONAL_ATTRIBUTES`: `settled_by`, `handoff_reason`,
  `store_url`, `expires_at`, `resolution`, `counts_toward_caps`) beyond
  their existing keywords, raising `ArgumentError` on anything else — the
  extension point `docs/plans/handoff-reconcile.md`'s Phase 1/2 use to
  record and settle a shopper-completed hand-off as a transaction record,
  not a parallel path. `#completed_since` now excludes
  `counts_toward_caps: false` records (Phase 2's `warn` spend mode); a
  record with neither field set reads exactly as before. No change to any
  existing caller.
- Fix: `Support::HttpClient#json_request` opened every request with no
  `open_timeout`/`read_timeout` of its own, so a hung upstream fell back to
  Net::HTTP's own 60s defaults on both — a full minute an agent loop could
  be stuck mid-checkout before anything reacted. It now defaults to a 5s
  open / 30s read timeout (mirroring `Check#get`'s own explicit precedent),
  overridable per call via `open_timeout:`/`read_timeout:` keywords.
  `Support::Retry#retryable_error?` now also treats `Net::OpenTimeout` and
  `Net::ReadTimeout` as retryable — neither carries a `status`, but both are
  exactly the "the upstream didn't do the work, try again" case the module
  exists for.
- Documentation only, no code change. Fixes the README's "Usage" snippet:
  it called `server.start` on the `MCP::Server` `Mcp::Server.build` returns,
  but that class (mcp gem 0.25.0) has no `#start` — only
  `MCP::Server::Transports::StdioTransport#open` reads stdio frames. Every
  bundled adapter's `exe/` had the same bug; this just fixes the README to
  match.

## [0.9.0] - 2026-09-23

- New `Support::OfferRanking` and `Support::Escalation`: the offer-ranking
  and escalation rules, held in core the way `PolicyGuard` holds the policy
  rule. `portage-ucp-decision`'s `OfferRanking` and `EscalationPolicy` wrap
  them, and `portage-cli` calls them directly, so there's one copy of each
  rule instead of a gem copy and a CLI fallback.
  - `OfferRanking.rank(offers) { |offer| [buyable, amount] }` puts buyable
    offers first, then priced, then cheapest, and keeps ties in input
    order.
  - `Escalation.reason(checkout_status:, warnings:)` returns
    `:requires_escalation`, then `:mismatch` for any warning, else nil.
- New `Support::Totals.amount(totals, type: "total")`, the reader for the
  arrays `Totals.summary`/`Totals.line` build. It takes `Total` value
  objects or wire hashes, and returns nil when there's no entry of that
  type. `Dispatcher` and `ReferenceAdapter` use it in place of their own
  copies of the lookup, as does `portage-cli`.
- Fix: `SchemaValidator` failed to load any vendored UCP schema in a process
  with no `LANG` set (a bare Docker image, a CI runner). The schemas contain
  non-ASCII, and Ruby then reads files as US-ASCII, so every validation
  raised `Encoding::InvalidByteSequenceError`. It now reads them as UTF-8.

## [0.8.1] - 2026-09-22

- `Resolver`'s WooCommerce platform entry threads `payment_method`/
  `billing_address` from `WOOCOMMERCE_PAYMENT_METHOD`/`WOOCOMMERCE_BILLING_ADDRESS`
  through to `Adapter.new`. It previously built the client and adapter
  without either, so `complete_checkout` failed with no gateway or address
  configured even when both env vars were set — the resolver's `env:` map
  simply never named them.

## [0.8.0] - 2026-09-17

- **Breaking:** `Manifest#to_h` now emits the shape live UCP stores actually
  serve (confirmed against Shopify's `2026-08-25` rollout) instead of the
  flat one this gem invented: everything nests under a top-level `ucp`
  object, `ucp_version` becomes `version`, and `capabilities` is keyed by
  capability name (`{"dev.ucp.shopping.catalog" => [{version: ...}]}`)
  rather than an array of `{name:, version:}` hashes. When a signer is
  configured the signature still covers the manifest body and rides inside
  the `ucp` object. Anything reading a Portage-served manifest by the old
  top-level keys needs updating — `Rack::ManifestEndpoint`'s own
  advertised-payment check and `skills/serve-via-ucp`'s `verify.sh` both
  did, and are fixed here.

## [0.7.1] - 2026-09-16

- No behavior change — 0.7.0 was built and pushed with `gem build` run from
  the workspace root instead of this gem's own directory, so
  `spec.files = Dir["lib/**/*.rb", ...]` resolved against the wrong working
  directory and packaged an empty gem (no `lib/`). 0.7.0 has been yanked;
  0.7.1 repackages the exact same 0.7.0 code correctly.

## [0.7.0] - 2026-09-16

- Added `Ap2::MandateSignature` — real ECDSA (P-256/P-384) verification of a
  `PaymentMandate#signature` against a JWK trust-anchor set (an array of JWKs,
  or a `#call(kid)` resolver), reusing the same wire conventions as the
  existing RFC 9421 `Security::Signature`. `MandateGuard.validate!` gains a
  `require_signature:` (default `false`) fail-closed option — with it set,
  a mandate that no trust key can verify raises `InvalidMandateError` instead
  of silently falling back to shape-only validation. `Configuration` gains
  `mandate_trusted_keys`/`require_mandate_signature` accessors, and
  `Dispatcher.new` gains matching `mandate_trust_keys:`/
  `require_mandate_signature:` kwargs. 0.6.0 shipped AP2 mandates shape-only
  ("no cryptographic verification" — see that entry below); this closes the
  gap. Also hardens the shape-only path itself: rejects non-EC JWKs before
  trusting `crv`/`x`/`y`, rescues `ArgumentError` in `decode_base64url` so a
  malformed base64url value raises `InvalidMandateError` rather than
  crashing, and stops leaking the raw curve/digest hash into the
  wrong-length error message.
- Closed a cross-process idempotency race: `FileStore` gains
  `#fetch_or_store`, an atomic check-then-set under one `LOCK_EX` (the
  previous fetch-then-store used two separate lock acquisitions, leaving a
  window for a duplicate charge). `Idempotency#dedup` now goes through it.
  `FileStore` persistence now writes to a temp file and `File.rename`s it
  into place instead of truncating in place, and locks a sidecar `.lock`
  file rather than the data file itself, so a lock held across a rename
  can't go stale. A poisoned or truncated data file is now rescued and
  treated as empty on read instead of permanently breaking every subsequent
  `portage` invocation. `Configuration` gains `idempotency_provider` so a
  caller can share one store process-wide instead of every
  `Idempotency`-including instance getting its own fresh `MemoryStore`.
  Per-key idempotency locks and `SessionLock`'s per-session locks are now
  refcounted and reaped after use instead of growing unbounded for the life
  of a long-running process.
- Added `Rails::Railtie` and a `rails g portage:ucp:install` generator,
  guarded so they only load when Rails is already present (the gemspec adds
  no Rails dependency of its own) — writes a `config/initializers/
  portage_ucp.rb` stub and mounts the manifest/webhook Rack endpoints with
  TODO placeholders for a Rails host to fill in.
- Added opt-in OpenTelemetry span emission: `Configuration#tracer` (`nil` by
  default, no OTel dependency added). When set to something responding to
  `#in_span(name, attributes:)`, `Observability.log` also emits a span
  alongside its existing JSON logging; a no-op otherwise.
- `Mcp::Server.build` now names `journal:` explicitly rather than leaving it
  to fall through `**server_opts`, forwarding it straight to
  `Dispatcher.new` — `Client.for_adapter`/`Loopback` already splatted
  `server_opts` through, but nothing constructed a `Dispatcher` with a
  journal regardless of what a caller passed. Closes design-log §37's named
  gap; see `portage-cli`'s own changelog for the loopback buy path this now
  lets `portage-cli` wire up.
- Added `#each_record`/`#all` to `TransactionLog`/`OrderLedger` (and to both
  classes' `Store` abstraction) — read-only enumeration over every stored
  record, additive alongside the existing keyed `#find`/`#completed_since`.
  §22 item 6's console is the second real consumer the `Store` docs said
  would trigger this; `FileStore` implements it under the same shared-file
  lock as every other read.

## [0.6.0] - 2026-09-15

- **Breaking:** `PaymentEnrollment` results are now validated by the new
  `PaymentEnrollmentGuard` (design-log §33/Phase B) — every
  `create_payment_enrollment`/`get_payment_enrollment` response an adapter
  returns is checked via `Dispatcher#call`: `status` must be `"pending"` or
  `"complete"`; `"pending"` must carry a `setup_url` and no `payment_token`;
  `"complete"` must carry a `payment_token` and no `setup_url`. Raises the
  new `Portage::Ucp::InvalidPaymentEnrollmentError` on a violation. A value
  that constructed fine before (e.g. `status: "banana"`, or `"complete"`
  with no token) now raises the first time it crosses `Dispatcher#call` —
  consumers of `PaymentEnrollment` (`portage-cli`, `portage-ucp-client`)
  are unaffected since they only branch on the CLI's own wire-level status
  string, never construct the object themselves.
- Added `Portage::Ucp::Ap2` — an AP2 mandate shape (design-log §33/Phase B,
  citing the AP2/UCP payment-handler gap already confirmed at design-log
  §29/§30). `Ap2::PaymentMandate` (amount, currency, merchant, expires_at,
  signature) and `Ap2::MandateGuard.validate!` (required fields + expiry —
  mandate-*shape* validation, not cryptographic AP2 verification; no key
  infrastructure or trust anchor exists in this repo to verify a signature
  against). `create_payment_enrollment`/`complete_checkout` take an
  optional `mandate:` kwarg, shape-checked by `Dispatcher#call` before any
  adapter sees it; `ReferenceAdapter` accepts one and echoes it back on the
  enrollment it returns. `PaymentEnrollment` gains an optional `mandate:`
  field for that echo (safe to add — it's a Portage extension, not a
  UCP-schema-validated type).
- Adapter conformance kit (`lib/portage/ucp/rspec.rb`) gains an
  `app.portage-ucp.payment_enrollment` example proving an adapter's
  enrollment responses satisfy `PaymentEnrollmentGuard` — previously the
  kit had zero enrollment coverage; the only existing assertions lived in
  this gem's own `reference_adapter_conformance_spec.rb`, which ships to
  nobody.
- `Support::TransactionLog` and `Support::OrderLedger` are now backed by a
  pluggable `Store` (design-log §33) — new `Store`/`FileStore` pair on
  each, mirroring `portage-ucp-journal`. `Dispatcher.new(transaction_log:,
  order_ledger:)` / `TransactionLog.new(store:)` / `OrderLedger.new(store:)`
  are the injection points; `path:`/`clock:` still work unchanged as a
  shorthand for the file-backed default. Pure extract-interface refactor —
  no behavior change, no new construction-site requirements.
- Added `app.portage-ucp.payment_method`, `app.portage-ucp.saved_address`, and
  `app.portage-ucp.shopper_data` — Portage-owned extensions (design-log §22
  item 7) for saved payment references, saved addresses, and shopper data
  erasure, shipped together per §16. `oauth_token:` is the authorization
  boundary on every method, including the two `list_*` reads, since
  `Mcp::Server` only authorizes/rate-limits calls carrying an
  `idempotency_key`. `save_payment_method`'s `payment_token:` runs through
  the existing `PaymentTokenGuard` via `Dispatcher#call`, same as
  `complete_checkout`. `ReferenceAdapter` implements all three; `Adapter`'s
  stubs raise `NotImplementedError` until overridden.
- `Dispatcher.new` gains an optional `journal:` argument (`nil` by default,
  never `require`d from this gem) — after a successful `complete_checkout`
  with a settled order, `@journal.record_checkout(shop:, source:, checkout:,
  idempotency_key:)` runs alongside the existing `order_ledger` write, same
  after-settle/outside-the-rescue posture. `source` is `"native_ucp"` or
  `"adapter:<platform>"`, read off the adapter's class. Pairs with the new
  `portage-ucp-journal` gem's `PurchaseJournal` (design-log §22,
  docs/plans/storage-abstraction-journal.md) — core takes on no new runtime
  dependency; a consumer wires the journal in from their own app.
- Added `Portage::Ucp::Security::Signature` and
  `Portage::Ucp::Rack::SignatureVerification` — verifies RFC 9421 HTTP
  Message Signatures on inbound requests per UCP's signature spec
  (`ucp.dev/2026-04-08/specification/signatures/`), the cryptographic
  proof-of-consent piece design-log §22 named as the one genuine security
  hole remaining before 1.0. Verify-before-parse, same posture as
  `Rack::WebhookEndpoint`; trusted keys reuse `Manifest#signing_keys`'
  current+next JWK-array shape rather than a second key config.
- Added `Confirmer::Webhook` (design-log §22 slice, Phase C) — out-of-band
  approval for the confirmation gate, alongside `Terminal`/`AutoApprove`.
  POSTs `{amount, currency, merchant, idempotency_key}` to a configured
  URL, then polls a configured status endpoint (or calls a caller-supplied
  `wait:` callback, for push-based transports) until approve/deny/timeout.
  Fails closed on timeout, same as `Terminal`, but with its own longer
  default timeout (900s vs. `Terminal`'s 120s) — a human already at a
  terminal isn't the same wait as noticing and acting on a Slack message.
  Built on `Support::HttpClient`, no new runtime dependency. Non-2xx
  responses from the confirm/status calls themselves raise the new
  `Confirmer::WebhookApiError`, distinct from `ConfirmationDeniedError`:
  one means the out-of-band approver couldn't be reached, the other means
  it was reached and said no (or never answered).

## [0.5.0] - 2026-09-14

- Added `Adapter#create_payment_enrollment(idempotency_key:)` /
  `#get_payment_enrollment(enrollment_id:)`, advertised as a new
  `app.portage-ucp.payment_enrollment` capability — a Portage extension, not
  part of the UCP spec. Starts a card-on-file enrollment without the card
  ever touching this process: `#create_payment_enrollment` returns a
  gateway-hosted `setup_url`, and the caller polls `#get_payment_enrollment`
  until `status` leaves `"pending"` and a `payment_token` appears.
  Implemented in `ReferenceAdapter` as a worked example (docs/plans/agentic-payments.md
  Phase 1).
- Made the idempotency dedup store pluggable — `Support::Idempotency` now
  takes a `store:` (defaulting to the existing in-memory behavior via the new
  `MemoryStore`), with a `FileStore` alternative for dedup that survives a
  process restart.
- Added a durable `Support::TransactionLog`, wired into
  `Dispatcher#complete_checkout` dispatch — a transaction is reserved before
  dispatch and marked settled/failed after, so a crash mid-charge leaves a
  diagnosable record instead of silence.
- Extended `TransactionLog` to also record policy decisions and confirmation
  outcomes on the same transaction record `PolicyGuard`/`Confirmer` gate.
- Added `PolicyGuard`, wired into `Dispatcher` just before `complete_checkout`
  dispatch — enforces `Policy`'s per-transaction/rolling caps, velocity, and
  merchant allowlist (docs/plans/agentic-payments.md Phase 2). Configured via
  `portage-cli`'s `portage policy show/set`.
- Added per-token enrollment scopes to `Policy` — a merchant/max-amount/
  currency scope can be bound to a token at enrollment time and is checked by
  `PolicyGuard` keyed by the same `token_ref` derived from the token at
  charge time.
- Added a `Confirmer` interface, wired into `Dispatcher` right after
  `PolicyGuard.check!` passes and before `complete_checkout` dispatch.
  `Confirmer::Terminal` blocks the process on stdin and fails closed on
  anything but an explicit `"y"` (no answer, `"n"`, or EOF all deny);
  `Confirmer::AutoApprove` is for specs/conformance kits (docs/plans/agentic-payments.md
  Phase 3).
- Added a durable `Support::OrderLedger`, wired into the `complete_checkout`
  settle path — written after the transaction record is already complete, so
  a failed snapshot write surfaces without flipping an already-settled charge
  to failed.
- `Mcp::Server.call_tool` now extracts `ucp-agent.profile` from `_meta` the
  same way it already does `correlation_id` from `traceparent`, logging/
  forwarding it as `agent_profile` through every transport (http, stdio,
  loopback) and `Client::Session`. Additive only — `Dispatcher` accepts and
  threads it without yet acting on it.
- Added `Adapter#lookup_catalog(ids:)`, advertised alongside `search_catalog`
  — fetches several known product ids in one round trip instead of one
  `get_product` call per id. Implemented in `Shopify::Adapter` via the Admin
  API's `nodes(ids:)` field, reusing the same `Mapper.product` shape
  `get_product`/`search_catalog` already use.

## [0.4.0] - 2026-08-28

- Added `Adapter#reorder(order_id:, idempotency_key:)`, advertised as a new
  `app.portage-ucp.reorder` capability — a Portage extension, not part of the
  UCP spec. Hydrates a `Cart` from a previous order's line items, re-checking
  each item's current price/availability rather than replaying the order's
  historical totals, and reports anything no longer purchasable via the new
  `ReorderResult#unavailable_items` rather than failing the whole call.
  Implemented in `ReferenceAdapter` as a worked example.
- `Mcp::Server.call_tool` now emits a minimal pre-auth `tool_call_received`
  event (capability, action, correlation id — no arguments) before
  `authorize`/`rate_limit` run, moving the full `tool_called` event
  (arguments included) below them. Previously the full event, arguments and
  all, was logged before authorization, so an unauthenticated caller could
  write attacker-chosen content into the operator's logs at whatever volume
  the rate limiter would otherwise have refused (design-log §23).
- `Mcp::Server.correlation_id_for` stamps both events with a correlation id
  read from the inbound W3C `traceparent` in `server_context[:_meta]`
  (SEP-414, `MCP::TraceContext`), falling back to `SecureRandom.uuid` when
  absent or malformed. Deliberately per-request, not per-session —
  `Server::Context` is built once per process in `.build`, and `mcp`
  0.25.0's Streamable HTTP transport is stateful and multi-session, so
  memoizing an id there would stamp every session in the process with the
  same value (design-log §23). Because `traceparent` is unauthenticated
  input read before `authorize`/`rate_limit` run, it's validated against
  the W3C Trace Context format before use rather than accepted as-is — a
  malformed or oversized value falls back to a generated id instead of
  reaching the pre-auth log or `Dispatcher`/`CheckoutState` unchecked.
- `Dispatcher` now threads its logger and each call's correlation id to the
  adapter for the duration of that one call
  (`Support::CheckoutState.with_observability`) so a
  `checkout_state_transition` event (§12) fires from `record_checkout_status`
  carrying the same correlation id as the `tool_called` event that triggered
  it — without adding a `correlation_id:` kwarg to any checkout method, which
  would have been a breaking change to the `Adapter` contract. Storage is
  `Thread.current`, keyed per adapter object and restored on exit, rather
  than an instance variable on the adapter: `Mcp::Server.build` constructs
  one adapter per process, shared across every concurrent session, so an
  instance variable would let two in-flight requests clobber each other's
  correlation id — the same per-process-state trap §23 diagnosed for the
  correlation id generator itself, one layer down. No `capability_negotiated`
  event yet: `CapabilityNegotiator#negotiate` has no call site anywhere in
  the gem outside its own spec, so there's nowhere to emit it from without
  building that call site first (design-log §23).
- `Observability::REDACTED_KEYS` grows past the three credential keys to
  cover the PII that actually flows through logged events — `email`
  (`Identity`, §3) and `first_name`/`last_name`/`phone_number`/
  `street_address`/`extended_address`/`address_locality`/`address_region`/
  `address_country`/`postal_code` (`PostalAddress`, fulfillment
  destinations). §12's "Money-adjacent PII" named no real key — `Money`/
  `Total` carry only amounts and currency codes (design-log §23 step 4).
- `Rack::WebhookEndpoint` takes a `logger:` kwarg (defaulting to
  `Portage::Ucp.configuration.logger`) and emits `order_webhook_received`
  (order id, checkout id) on a verified payload and `order_webhook_rejected`
  (reason: `invalid_signature` or `bad_request`) on the two rejection paths
  — never the request body. No new `config.event_sink`: this endpoint is a
  plain Rack app never built through `Mcp::Server.build`, so it can't reach
  `mcp`'s own request hooks, and threading the gem's existing `logger:`
  convention through one more constructor was the whole fix (design-log
  §23 step 5).

## [0.3.0] - 2026-08-27

- `Portage::Ucp::Support::Retry` (`lib/portage/ucp/support/retry.rb`) —
  bounded retry with backoff for adapters, plus normalized conflict/throttle
  errors on `Support::ApiError` so a caller can distinguish "retry this" from
  "don't."
- `Portage::Ucp::Support::SessionLock` (`lib/portage/ucp/support/session_lock.rb`)
  — serializes per-cart/checkout mutations against a single upstream session,
  used by the Shopify and Wix adapters to stop concurrent cart writes from
  racing the same checkout.
- `Support::Idempotency` is now thread-safe under concurrent duplicate calls
  — the dedup table write was not atomic, so two requests with the same
  idempotency key arriving together could both miss the cache and both hit
  the adapter.
- Conformance kit: the repeated-idempotency-key example no longer passes on
  output equality alone. An adapter wired to a fixed-response test double
  returns identical output whether or not it deduped, so the example now also
  asserts the key reached `Support::Idempotency`'s dedup table when the
  adapter includes that module, and `warn`s (rather than silently passing)
  when it doesn't.

- `Portage::Ucp::ReferenceAdapter` (`lib/portage/ucp/reference_adapter.rb`) —
  the in-memory `Adapter` roadmap §8 step 1 called for and design-log §17
  flagged as missing outside `spec/support/fake_adapter.rb`, ships with the
  gem now. Implements every capability including
  `discount_codes_supported?`/`fulfillment_supported?`/`link_identity` — the
  first adapter in this repo to back identity linking at all.
- `Portage::Ucp::RSpec`/`portage/ucp/rspec.rb` — the adapter conformance kit
  design-log §17 called "the missing piece that turns 'any backend that
  implements Adapter' from a README claim into something checked": an
  `it_behaves_like "a portage adapter"` shared-examples suite checking the
  contract's behavioral guarantees (idempotency dedup, the PAN guard,
  schema-conformant wire output, `OutOfStockError` on a stale-stock line) —
  not loaded by `require "portage/ucp"`, opt-in via `require
  "portage/ucp/rspec"` since it pulls in RSpec itself. Exercised against
  `ReferenceAdapter` in this gem's own suite
  (`spec/reference_adapter_conformance_spec.rb`); wired into each adapter
  gem's own spec suite (`spec/portage/ucp/<platform>/conformance_spec.rb`)
  as follow-up.
- Conformance kit: `existing_variant_id` alongside `existing_product_id`, for
  adapters (Shopify) where a catalog lookup id and a cart line-item id are
  different GIDs. Defaults to `existing_product_id`, so every other adapter
  is unaffected.
- `search_catalog`/`get_product` output is schema-wrapped like every other
  capability now — previously returned a bare array/`Product` with no
  `to_wire_h`, so the dispatcher's schema-wrap never touched it and nothing
  caught it drifting from `catalog_search.json`/`catalog_lookup.json`.

## [0.2.0] - 2026-08-21

- `Portage::Ucp::OutOfStockError` — the contract for `#complete_checkout`
  (design-log §16 "Stock/availability going stale") now documents that
  adapters should raise it when the platform rejects completion over a
  no-longer-available line item, instead of re-checking with a separate call
  agents could forget to make.
- `Adapter#cancel_order`, `#request_return`, `#refund_order` — a gem-side
  extension of `dev.ucp.shopping.order` (design-log §16 "Order changes"),
  since the real UCP spec's order lifecycle is get-only. Each returns the
  updated `Order`, with the change recorded as an appended
  `Portage::Ucp::Adjustment`.
- `Capability#predicate` — a minimal escape hatch for extensions that add
  fields rather than actions (`dev.ucp.shopping.discount`,
  `dev.ucp.shopping.fulfillment`): a capability can name an adapter method
  instead of an action set, and `#advertised_for?` asks it directly.
  `create_cart`/`update_cart`/`create_checkout`/`update_checkout` gain an
  optional `discount_codes:` param defaulting to `nil` (not `[]`), so "not
  mentioned" and "clear the codes" stay distinguishable.
- `dev.ucp.shopping.fulfillment` — the vendored extension for picking a
  shipping method/rate or pickup location during checkout. New value objects
  `PostalAddress`, `ShippingDestination`, `RetailLocation`,
  `FulfillmentOption`, `FulfillmentGroup`, `FulfillmentMethod`, and the
  `CheckoutFulfillment` container (named apart from `Fulfillment`, which
  Order's post-purchase container already owns — see design-log).

## [0.1.0] - 2026-08-14

- Initial pre-release. Protocol-only core: `Adapter` contract, capability
  registry, manifest builder, MCP server wrapper, offline `SchemaValidator`,
  `portage-ucp-check` CLI.
- `Portage::Ucp::Support`: shared building blocks the adapter gems mix in
  (money conversion, totals shapes, idempotency dedup, checkout-state
  tracking, `ApiError`, 404-to-nil reads, Net::HTTP JSON client, OAuth token
  exchange). Not used by the core gem's own request path.
