# Design log — Portage::Ucp

**This is a historical record, not current documentation.** It captures the
research and the decisions behind the gem's shape, dated as they were made
against the specs as they read at the time. Where it disagrees with the code,
the code wins; where it disagrees with a README, the README wins. Kept because
the *reasoning* is hard to reconstruct from a diff — particularly §1 (what the
specs actually say), §7 (resolved decisions), §9 (the payment boundary), and §14
(why Etsy and Instagram can't back a real checkout).

**Naming (decided 2026-07-27)**: drafted under the name `ucp_mcp`, shipped as
**`Portage::Ucp`** — gem `portage-ucp` (core), `portage-ucp-<platform>`
(adapters). "Portage" — carrying cargo overland between waterways it can't sail
directly between — reflects what the gem does: carries commerce operations
across platforms (§14) that don't natively speak UCP or speak to each other,
without overclaiming a frictionless crossing (see §14's Wix checkout-redirect
finding). Considered and rejected: `ucp_mcp` (too acronym-dense, reads as *the*
canonical UCP implementation rather than *an* adapter), `Vessel` (taken on
RubyGems — unrelated web-crawler gem, 40k downloads), `ShopBot` (implies an
autonomous agent/chatbot, which this isn't — no LLM call or decision loop lives
here), `UniCart` (narrows five capabilities to one, and "Uni-" overclaims
uniformity the Wix finding disproves), `Active UCP` (borrows Rails-core
"Active*" naming equity the gem hasn't earned and still centers the acronym).
Names below are shown as shipped, not as drafted.

## 0. What this is, in one paragraph

An open-source Ruby gem — for anyone in the world, on any e-commerce stack — that lets a
commerce backend expose itself to AI shopping agents over two protocols at once: **MCP**
(Model Context Protocol — the tool/resource interface an LLM agent talks over) and **UCP**
(Universal Commerce Protocol — the commerce-specific capability/negotiation layer that sits
on top of MCP, REST, or A2A as a transport). It is tied to no single merchant's
business logic: the gem must not assume any particular consumer's deployment
shape, hosting model, existing API client stack, or domain concerns. That
coupling would defeat the point of an open, general-purpose gem.

**Correction / provenance note**: an earlier draft of this plan proposed a
Shopify-only gem called `shopify_mcp` with invented dependencies (`json-rpc ~> 0.2`,
`shopify_api >= 14.0`). That draft is discarded. Names, dependencies, and scope below come
from reading the actual current specs.

## 1. Grounding: what the specs actually say (checked 2026-07-23)

**MCP** — [modelcontextprotocol/modelcontextprotocol](https://github.com/modelcontextprotocol/modelcontextprotocol), spec at modelcontextprotocol.io:
- Latest stable spec version: **2025-11-25** (prior stable: 2025-06-18; baseline: 2024-11-05).
- Wire format: JSON-RPC 2.0. Lifecycle: `initialize` handshake with capability
  negotiation, then `tools/list`, `tools/call`, plus optional `resources/*` and `prompts/*`.
- Transports: stdio, and Streamable HTTP (SSE-capable, Rack-compatible).
- **There is an official Ruby SDK**: the [`mcp`](https://rubygems.org/gems/mcp) gem
  (current **`0.24.0`**, released 2026-07-12), maintained under the modelcontextprotocol org
  (`modelcontextprotocol/ruby-sdk`, developed in collaboration with Shopify). It already
  implements JSON-RPC 2.0 handling, tool / resource / prompt registration, stdio transport,
  Streamable HTTP transport (Rack app), and has first-class Rails mount/controller integration.
  Licensed **Apache-2.0** (not MIT — matters for §7 decision 4).
  → **We build on top of this gem, we do not hand-roll JSON-RPC.** Reinventing the
  transport layer would immediately be behind "latest tech."

**UCP** — [universal-commerce-protocol/ucp](https://github.com/universal-commerce-protocol/ucp), spec at [ucp.dev](https://ucp.dev/2026-04-08/specification/overview/), also documented by Google ([developers.google.com/merchant/ucp](https://developers.google.com/merchant/ucp)):
- Current spec version: **2026-04-08**.
- UCP is **transport-agnostic**: capabilities can be offered over REST, over MCP
  (`tools/call` with dual `structuredContent` + serialized `content` output), or over A2A.
  MCP is a supported binding, not the foundation.
- Discovery: a `/.well-known/ucp` JSON manifest — business profile, supported
  capabilities, payment handlers, signing keys.
- Capabilities are namespaced reverse-domain style (e.g. `dev.ucp.shopping.checkout`) and
  version-negotiated: platform and business each advertise supported capability versions,
  server picks the intersection.
- Core capability families: **Checkout**, **Cart**, **Catalog**, **Order** (lifecycle /
  webhooks), **Identity Linking** (OAuth 2.0), plus payment-token-exchange handlers.
- Repo ships machine-readable schemas per service (e.g.
  `source/services/shopping/{mcp,rest,embedded,permalink}.openrpc|openapi.json`) — these
  are the actual contract to validate against, not hand-derived JSON.

**Shopify's own UCP story** (verified 2026-07-23 against ucpchecker.com, ucptools.dev,
wearepresta.com, shopify.engineering — independently corroborated, claim confirmed):
- Shopify ships a **native "Universal Commerce Agent" app** (Shopify App Store, real,
  confirmed by three independent sources) that auto-generates and serves `/.well-known/ucp`
  for a store, with no manual config, currently advertising protocol version `2026-01-23`
  (confirmed verbatim — "vast majority of Shopify stores already on this version"). It
  covers standard Checkout + Orders capabilities out of the box.
- The guide's explicit advice: **don't reimplement this for a standard store** — install
  the app, validate the manifest, test with real agent sessions.
- **Gap found, strengthens this gem's case**: Shopify's native app does **NOT** generate
  cryptographic signing keys for its manifest. Agents that verify manifest authenticity
  (Google's agents specifically) treat a `signing_keys`-less manifest as unverified. This
  is a concrete, documented shortfall of the native app — not hypothetical — and directly
  motivates §9's manifest-signing requirement (consumer-provided keys, rotation-ready key
  set) as a real differentiator, not just defensive hardening.
- **Implication for this gem**: this gem's Shopify adapter is for the case Shopify's own
  app doesn't cover — a merchant or developer running their own Ruby app/gateway who wants
  a drop-in UCP/MCP layer over standard Shopify Admin/Storefront primitives (catalog,
  cart, checkout, orders), generically, **or who needs a signed manifest the native app
  can't provide**. It does not model any one merchant's bespoke checkout logic
  (subscriptions, bundles, whatever) — a merchant with custom semantics writes their own
  thin `Adapter`, same as anyone on any other backend would (§3).
- Note: the app's advertised protocol version (`2026-01-23`) trails the current spec
  version this plan targets (`2026-04-08`, §41) — consistent with the app lagging spec,
  another reason a from-scratch gem tracking latest spec has a niche.

## 2. Architectural shape

Two gems, not one, mirroring how Faraday/Devise/OmniAuth split core-protocol-vs-adapter:

```
portage-ucp                  (core gem — protocol-only, zero commerce-backend deps)
portage-ucp-shopify          (adapter gem — depends on portage-ucp + shopify_api)
```

Rationale: an open-source gem "for anyone in the world on Shopify or any stack" cannot
force a `shopify_api` runtime dependency onto a Sinatra-plus-WooCommerce-REST user. The
core gem defines the protocol plumbing and an `Adapter` contract; backend-specific gems
(Shopify first, others as the community wants them) implement that contract.

### 2.1 `portage-ucp` (core)

```
portage-ucp.gemspec
lib/portage/ucp.rb                      # namespace entrypoint, config
lib/portage/ucp/version.rb
lib/portage/ucp/configuration.rb        # Portage::Ucp.configure { |c| c.adapter = ... }
lib/portage/ucp/adapter.rb              # abstract contract (see §3)
lib/portage/ucp/manifest.rb             # builds /.well-known/ucp JSON from an Adapter
lib/portage/ucp/capability.rb           # capability registry + reverse-domain namespacing
                                     #   + advertise-if-adapter-method-overridden (§3, §7.6)
lib/portage/ucp/capability_negotiator.rb # single negotiator, transport-independent (§10):
                                     #   UCP-Agent header (HTTP) or initialize params (stdio)
lib/portage/ucp/value_objects.rb        # Money/Product/LineItem/Cart/Checkout/Order/Identity (§3.1)
lib/portage/ucp/authenticator.rb        # pluggable auth contract; no anon-mutation default (§9)
lib/portage/ucp/capabilities/
  checkout.rb                       # dev.ucp.shopping.checkout — maps to Adapter#create_checkout etc.
  cart.rb                           # dev.ucp.shopping.cart
  catalog.rb                        # dev.ucp.shopping.catalog
  order.rb                          # dev.ucp.shopping.order
  identity_linking.rb               # dev.ucp.shopping.identity (OAuth 2.0 token exchange)
lib/portage/ucp/mcp/
  server.rb                         # thin wrapper: builds an MCP::Server (from the `mcp`
                                     #   gem) whose tools are generated from registered
                                     #   Capabilities, so tool schemas and REST/UCP schemas
                                     #   stay in sync instead of hand-duplicated
  tools/                            # one MCP::Tool subclass per capability action
    search_catalog_tool.rb
    get_product_tool.rb
    create_checkout_tool.rb
    update_checkout_tool.rb
    complete_checkout_tool.rb
lib/portage/ucp/rack/
  manifest_endpoint.rb              # Rack app serving GET /.well-known/ucp (signed, §9)
  webhook_endpoint.rb               # inbound order-lifecycle webhooks, HMAC-verify first (§11)
lib/portage/ucp/errors.rb               # JSON-RPC error mapping (-32601/-32602/etc.),
                                     # UCP-specific error envelope
spec/
  spec_helper.rb
  capability_spec.rb
  manifest_spec.rb
  mcp/server_spec.rb
  support/fake_adapter.rb           # in-memory Adapter impl used across specs
```

### 2.2 `portage-ucp-shopify` (Shopify adapter)

```
portage-ucp-shopify.gemspec              # depends on portage-ucp (~> 0.1), shopify_api (latest 2.x)
lib/portage/ucp/shopify/adapter.rb       # implements Portage::Ucp::Adapter against Shopify
lib/portage/ucp/shopify/client.rb        # thin wrapper choosing which Shopify GraphQL stack
                                      # to call through — must not force a redundant
                                      # GraphQL client stack on a consuming app
lib/portage/ucp/shopify/checkout_session.rb  # maps UCP checkout state <-> Shopify cart/
                                          # checkout + (if in scope) subscription
                                          # attributes
spec/
```

## 3. The `Adapter` contract (core gem's only real abstraction)

`Portage::Ucp::Adapter` is a plain Ruby interface (documented via YARD `@abstract`, not a DSL —
deliberately avoiding metaprogramming). Any backend implements:

**Design rule: every method has a default body that raises `Portage::Ucp::NotImplementedError`,
not a bare `raise`.** The capability registry (§2.1) advertises a capability in the manifest
*only if* its backing adapter method is overridden (`adapter.class.instance_method(:x).owner
!= Portage::Ucp::Adapter`). This is what lets the contract grow (add Cart, Identity, etc.) across
minor versions **without breaking existing adapters** — an adapter that doesn't implement a
new method simply doesn't advertise that capability, rather than 500ing at call time. This
resolves the versioning trap in §7.6.

```ruby
module Portage::Ucp
  # @abstract Subclass and override the methods for the capabilities you support.
  #   Unoverridden methods leave that capability out of the manifest (see §2.1).
  class Adapter
    # --- Catalog (dev.ucp.shopping.catalog) ---
    # @return [Array<Portage::Ucp::Product>]
    def search_catalog(query:, limit:); not_implemented; end
    # @return [Portage::Ucp::Product, nil]
    def get_product(product_id:); not_implemented; end

    # --- Cart (dev.ucp.shopping.cart) ---
    # @return [Portage::Ucp::Cart]
    def get_cart(cart_id:); not_implemented; end
    # @return [Portage::Ucp::Cart]
    def add_line_item(cart_id:, product_id:, quantity:, idempotency_key:); not_implemented; end
    # @return [Portage::Ucp::Cart]
    def remove_line_item(cart_id:, line_item_id:, idempotency_key:); not_implemented; end

    # --- Checkout (dev.ucp.shopping.checkout) ---
    # @return [Portage::Ucp::Checkout]
    def create_checkout(line_items:, idempotency_key:); not_implemented; end
    # @return [Portage::Ucp::Checkout]
    def update_checkout(checkout_id:, updates:, idempotency_key:); not_implemented; end
    # @param payment_token [String] single-use token from a UCP payment handler / AP2
    #   exchange — NEVER a raw PAN. See §9.
    # @return [Portage::Ucp::Checkout]
    def complete_checkout(checkout_id:, payment_token:, idempotency_key:); not_implemented; end

    # --- Order (dev.ucp.shopping.order) ---
    # @return [Portage::Ucp::Order, nil]
    def get_order(order_id:); not_implemented; end

    # --- Identity Linking (dev.ucp.shopping.identity, OAuth 2.0) ---
    # @return [Portage::Ucp::Identity] linked profile for an exchanged OAuth token
    def link_identity(oauth_token:); not_implemented; end

    private def not_implemented
      raise Portage::Ucp::NotImplementedError, "#{self.class} does not implement this capability"
    end
  end
end
```

**Idempotency (§9a).** Every mutating method takes an `idempotency_key:` — supplied by the
agent, echoed from the MCP tool call. Adapters MUST return the original result for a repeated
key rather than re-running the mutation. Without this, an agent retry on a dropped connection
double-charges. The core gem does not persist keys itself (no storage assumption); it threads
the key through and documents the contract, and the reference in-memory adapter demonstrates
correct dedup.

### 3.1 Value objects

Plain immutable structs (`Data.define`), the shared vocabulary across capability, tool, and
adapter layers — nothing Shopify-shaped leaks into the protocol layer.

```ruby
Money    = Data.define(:amount_minor, :currency)   # integer minor units + ISO-4217 code.
                                                    #   NEVER a float. All prices are Money.
Product  = Data.define(:id, :title, :description, :price, :available, :variants, :url)
LineItem = Data.define(:id, :product_id, :quantity, :unit_price, :total)
Cart     = Data.define(:id, :line_items, :subtotal, :currency)
Checkout = Data.define(:id, :status, :line_items, :subtotal, :tax, :total,
                       :currency, :locale, :available_payment_handlers)
Order    = Data.define(:id, :status, :line_items, :total, :currency, :placed_at)
Identity = Data.define(:subject, :email, :linked_at)
```

`Money`, currency, tax, and locale are first-class from day one — retrofitting money handling
after floats have leaked in is the classic commerce-gem regret.

## 4. What the gem expects of an adopter

No specific consumer's architecture constrains this design — not its hosting
model, its existing API client stacks, its subscription or domain concerns, its
webhook topology. Anyone adopting `portage-ucp`, on a Rails app, on Sinatra, on
anything, is expected to:
- provide their own credentials/session handling to whatever backend they're adapting
  (the gem's `Adapter` contract takes plain arguments and returns plain value objects; it
  has no opinion on how an adapter authenticates internally);
- mount the generated Rack manifest/MCP endpoints however suits their own app (in-process
  or standalone — see §7, resolved as "consumer's choice, gem stays deployment-agnostic");
- write their own `Adapter` subclass if their checkout semantics are anything other than
  standard catalog/cart/checkout/order (see §7, resolved as "generic only").

## 5. Protocol implementation checklist

- [ ] JSON-RPC 2.0 via the `mcp` gem: correct error codes surfaced (-32601 Method Not
      Found, -32602 Invalid Params) — the `mcp` gem already does this; verify it, don't
      reimplement it.
- [ ] `initialize` handshake reports `server_info` (`name:`, version) and `capabilities:
      { tools: {} }` (and `resources`/`prompts` only if/when actually implemented).
- [ ] `tools/list` schemas generated from `Portage::Ucp::Capability` definitions, not hand-typed
      twice (once for MCP, once for the UCP REST/OpenAPI shape) — single source of truth.
- [ ] `tools/call` routes through the registered `Adapter`, wraps the result as MCP
      `content` (text block) **and** `structuredContent`, matching UCP's documented
      dual-output convention.
- [ ] `/.well-known/ucp` manifest: protocol version, capability list w/ reverse-domain
      names + versions, payment handler declarations, signing key info.
- [ ] Capability version negotiation: intersection of platform-advertised (`UCP-Agent`
      header) and business-advertised capability versions.
- [ ] Validate the generated manifest against UCP's published OpenAPI/OpenRPC schemas
      (`source/services/shopping/*.json` in the ucp repo) and against
      [ucpchecker.com](https://ucpchecker.com)'s validator before calling any capability
      "done."

## 6. Dependencies (verified, not guessed)

Runtime (core `portage-ucp`):
- `mcp` (official Ruby MCP SDK, `~> 0.24`) — JSON-RPC/transport layer. Pre-1.0, so pin
  pessimistically and track breaking changes on each bump.
- No HTTP client dependency in core — adapters bring their own.

Runtime (`portage-ucp-shopify`):
- `portage-ucp` (path/git dependent during development, then version-pinned).
- `shopify_api` (official gem, latest 2.x) — the adapter builds its own minimal
  `ShopifyAPI::Clients::Graphql::Admin` session from credentials passed in at
  configuration time. It does not assume or depend on any host app's existing GraphQL
  client stack, session store, or auth strategy — that would break the "works for anyone"
  goal.

Development (both gems):
- `rspec` (~> 3.13, current major), verifying doubles / WebMock for any HTTP boundary.
- `rubocop` for style consistency.
- `yard` for public-API documentation (every public method gets a doc comment — no
  obscure metaprogramming, per the code-generation style this plan follows throughout).

Ruby version: target **3.4** (current stable line); gemspec's `required_ruby_version`
kept permissive (`>= 3.2`) so the gem doesn't force consumers onto a specific pin.

## 7. Decisions (resolved 2026-07-23)

1. **Checkout scope — resolved: generic only.** `portage-ucp-shopify`'s `create_checkout` (and
   the core gem generally) models only standard, universal commerce primitives —
   catalog/cart/checkout/order. No single merchant's
   business logic gets baked into the gem. Anyone with bespoke checkout semantics writes
   their own `Adapter` on top of the same contract.
2. **Server vs. client — resolved: server only, for now.** The gem's job is to let a
   backend *expose itself* to agents (UCP/MCP server side). Acting as an outbound
   UCP/MCP *client* (calling other agents/services) is out of scope — no evidence any
   real use case needs it, and it's a meaningfully different feature set were it ever
   wanted later.
3. **Deploy shape — resolved: deployment-agnostic by design.** This is a library for Ruby
   developers building UCP/MCP servers, not a hosted service or an opinionated app
   template. It ships a Rack app (manifest + MCP endpoints) that a consumer can mount
   inside any existing app or run standalone — the gem itself makes no assumption about
   process model, host framework, or infrastructure.
4. **License — resolved: MIT.** Matches the UCP reference repo. (The `mcp` gem itself is
   Apache-2.0; depending on an Apache-2.0 gem from an MIT gem is fine — both permissive, no
   copyleft conflict — but the gem's own LICENSE is MIT by choice, not because the deps are.)
   Gem names `portage-ucp` / `portage-ucp-shopify` confirmed unclaimed on RubyGems as of 2026-07-23.
5. **Spec versioning — resolved: pin one spec version per major release.** `portage-ucp` 0.x
   targets MCP 2025-11-25 + UCP 2026-04-08 only; a future breaking spec revision bumps the
   gem's major version rather than the gem trying to negotiate across spec versions
   internally.
6. **Adapter contract evolution — resolved: default-raise + advertise-if-overridden.** The
   `Adapter` is public API third parties implement, so adding a method must not break their
   subclasses. Every method defaults to raising `Portage::Ucp::NotImplementedError`; a capability
   is advertised only when its method is overridden (§3). New capabilities ship in minor
   versions; existing adapters keep working and simply don't advertise what they haven't
   implemented.

## 8. Roadmap

1. Scaffold `portage-ucp` core gem: `Adapter` contract, `Product`/`Checkout` value objects,
   capability registry, manifest builder. Ship with an in-memory reference `Adapter` for
   examples/specs — no real backend required to prove the protocol layer works.
2. Wrap the `mcp` gem: generate `MCP::Tool` subclasses from capability definitions,
   confirm `tools/list`/`tools/call` round-trip against the reference adapter, verify
   against MCP 2025-11-25's `initialize`/capabilities negotiation.
3. Build `/.well-known/ucp` manifest generation + validate against UCP's own OpenAPI/
   OpenRPC schemas and ucpchecker.com.
4. Build `portage-ucp-shopify`'s generic adapter directly against `shopify_api`'s
   Admin GraphQL client — standard catalog/cart/checkout/order only, no bespoke logic.
5. Integration-test a full agent-checkout handshake against a real Shopify dev store, side
   by side with the native Universal Commerce Agent app, to confirm no manifest/capability
   collision.
6. Publish both gems to RubyGems under MIT; write README/usage docs aimed at third-party
   adapter authors — the actual audience for this project.

**Ordering note (revised):** security (§9), idempotency, and the `Money` value object are
foundation, not polish — they land in roadmap step 1, not retrofitted after the Shopify
adapter. UCP schemas are vendored into the repo in step 1 too, so validation is offline from
day one and step 3's validation gate has no network dependency.

## 9. Security & payment boundary

A protocol that completes purchases and exchanges OAuth identity is a money-and-PII surface;
this section is a hard requirement, not optional hardening.

**Endpoint authentication.** The MCP tool endpoints and the manifest endpoint have different
postures:
- `GET /.well-known/ucp` is public by design (discovery) — but it is **signed**, so agents
  can verify authenticity (see manifest signing below).
- `tools/call` mutations (checkout/cart/identity) MUST NOT be open. The core gem ships a
  pluggable `Portage::Ucp.config.authenticator` (a callable given the Rack request / MCP session,
  returning an auth context or raising). It ships **no default that allows anonymous
  mutation** — an unconfigured server rejects mutating calls. Read-only catalog calls MAY be
  left open at the consumer's explicit choice.
- Consumers deploying over Streamable HTTP are responsible for TLS termination; the gem
  documents this and refuses to serve payment-handler declarations over plaintext HTTP.

**Manifest signing & key management.** The `/.well-known/ucp` manifest advertises signing
keys per the UCP spec. The gem:
- takes signing keys from consumer-provided config (never generates/stores keys implicitly);
- supports a **key set** (current + next) so keys can rotate without downtime;
- documents rotation as a consumer responsibility and never writes keys to disk itself.

**Payment token boundary (PCI).** `complete_checkout` takes a `payment_token` that is a
**single-use, tokenized credential** produced by a UCP payment handler / AP2 exchange —
never a raw PAN or card data. The gem:
- documents this boundary loudly and validates the token is opaque (rejects anything
  resembling a PAN via a Luhn/format guard, so a misintegrated agent can't push card numbers
  through the gem);
- never logs `payment_token`, `oauth_token`, or `Authorization` values (redaction in §12);
- keeps card data entirely out of scope — the gem is not in the cardholder data environment,
  and the docs say so explicitly so adopters don't assume otherwise.

**Rate limiting & abuse.** The gem exposes hooks for per-session/per-key rate limiting on
mutating capabilities but does not bundle a limiter (no storage assumption); docs recommend
one and the reference adapter demonstrates the hook.

## 10. Capability negotiation — two layers, reconciled

MCP already negotiates capabilities in the `initialize` handshake. UCP layers its own
capability-version negotiation on top. These are not redundant; they answer different
questions, and the gem keeps them explicit:
- **MCP `initialize`** negotiates *protocol features* (tools/resources/prompts). The gem
  reports `capabilities: { tools: {} }` here — transport-level.
- **UCP capability versions** negotiate *which commerce capability versions* both sides speak
  (e.g. `dev.ucp.shopping.checkout` v1 vs v2). Over the **HTTP** binding this uses the
  `UCP-Agent` request header (platform-advertised) intersected with the manifest
  (business-advertised).
- **Over stdio there are no HTTP headers.** For the stdio transport the gem carries the
  agent's advertised UCP capability versions in the `initialize` params
  (`_meta`/clientInfo extension) instead of a header, and falls back to "offer all
  business-advertised versions, newest-first" if the agent advertises none. This gap was
  unaddressed in the original draft and is the reason negotiation lives in one
  `CapabilityNegotiator` regardless of transport.

## 11. Order lifecycle & webhooks

UCP's Order capability includes lifecycle webhooks (order placed/updated/fulfilled). The
original design had no inbound path. Added:
- `Portage::Ucp::Rack::WebhookEndpoint` — receives backend order-status callbacks, **verifies
  signature/HMAC before parsing body** (verify first, parse second),
  normalizes to `Portage::Ucp::Order`, and hands off to a consumer-registered
  `config.on_order_event` callback.
- Outbound agent notifications (telling the agent an order changed) are deferred with the
  rest of the client/outbound scope (§7.2) — receiving backend webhooks is in; being a UCP
  client is out.

## 12. Observability

**This section was aspirational from §0 through 2026-08-27** — it described the
intended shape before most of it existed. §23 reconciled it against the code
(finding only one of three promised event types actually fired, an
arguments-logged-before-auth ordering bug, and a correlation-id design that
would have collided across sessions) and §23/§24's steps 1–6 are what's below
now: what the gem actually does, not what it was meant to.

Every event is a single `Portage::Ucp::Observability.log(logger, event, **fields)`
call — one JSON line (`{"event" => ..., **fields}`), through a consumer-injected
`Logger`-like object (`config.logger`, defaults to `Logger.new($stdout)`). There
is no APM-specific instrumentation and no `config.event_sink` — see below.

**Event types, and where each actually fires:**
- `tool_call_received` — `Mcp::Server.call_tool`, emitted *before*
  `authorize`/`rate_limit` run. Carries `capability`, `action`, `correlation_id`
  only — deliberately no `arguments`, since this fires for every caller
  including ones that go on to fail auth (§23 step 1).
- `tool_called` — same call site, emitted only *after* both `authorize` and
  `rate_limit` pass. Carries `capability`, `action`, `correlation_id`, and the
  full `arguments` hash.
- `checkout_state_transition` — `Support::CheckoutState#record_checkout_status`,
  adapter-side. Only fires when the adapter is called through `Dispatcher`
  (which sets `[logger, correlation_id]` on it via `#ucp_observability=`
  immediately before each call, §23 step 3); an adapter invoked directly
  bypasses this and the event silently doesn't fire — there is no other call
  path today. Carries `checkout_id`, `status`, `correlation_id`.
- `order_webhook_received` / `order_webhook_rejected` — `Rack::WebhookEndpoint`
  (§11, §23 step 5), a plain Rack app never built through `Mcp::Server.build`
  and so structurally outside `mcp`'s own request hooks. Takes its own
  `logger:` (same `config.logger` default as everything else). `received`
  carries `order_id`/`checkout_id` on a verified payload; `rejected` carries
  `reason` (`invalid_signature` or `bad_request`) on the two rejection paths —
  never the request body, before or after signature verification.
- `capability_negotiated` — **not emitted.** `CapabilityNegotiator#negotiate`
  (§10) has no call site anywhere in the gem outside its own spec, so there's
  nowhere to log from; noted in `capability_negotiator.rb` for whoever builds
  that call site next. Dropped from the list above rather than promised and
  unfulfilled a second time.

**Correlation id is per-request, not per-session** (§23 step 2, §24). MCP's
Streamable HTTP transport is stateful and multi-session — one `MCP::Server`
serves many sessions — so memoizing an id anywhere per-process (the original,
wrong instinct) would stamp every session with the same value.
`Server.correlation_id_for(server_context)` instead reads the inbound W3C
Trace Context `traceparent` from `server_context[:_meta]` (SEP-414,
`MCP::TraceContext`, passed through by the `mcp` gem untouched) and falls back
to `SecureRandom.uuid` only when absent, so an agent that already traces its
own calls gets one trace across both sides. `tool_call_received`/`tool_called`
for one call share the id; two calls in one process never share a generated
one. `checkout_state_transition` and the webhook events carry a correlation
id the same way, threaded from the same request.

**Redaction.** `Observability::REDACTED_KEYS` (`payment_token`, `oauth_token`,
`authorization`, `email`, `first_name`, `last_name`, `phone_number`,
`street_address`, `extended_address`, `address_locality`, `address_region`,
`address_country`, `postal_code`) is applied recursively through any hash or
array nesting depth before a field reaches the log. `email` covers
`Identity` (§3, identity-linking results); the rest cover `PostalAddress`
(fulfillment destinations). `Money`/`Total` carry only amounts and currency
codes — no PII — so "Money-adjacent PII," this section's original phrase,
named no real key and is gone (§23 step 4).

**No `config.event_sink`.** §23 raised it as a possible seam for events that
fire outside an MCP request; §24 built the concrete case
(`Rack::WebhookEndpoint`) and found a dedicated interface unjustified —
threading the existing `config.logger` convention through one more
constructor (`logger:`, same default everywhere else) was the whole fix. If a
second, genuinely-outside-a-request producer shows up later, decide then
whether one new config option still isn't enough.

## 13. Testing strategy (expanded)

- Vendor UCP's OpenRPC/OpenAPI schemas (`source/services/shopping/*.json`) **into the repo**;
  validate generated manifest + tool schemas against them in CI, offline.
- ucpchecker.com is a **manual pre-release** check only — never a CI gate (external network
  dependency, brittle).
- WebMock/verifying doubles for the Shopify HTTP boundary; no live calls in unit specs.
- Idempotency spec: same `idempotency_key` twice → one mutation, identical result.
- Negotiation spec: HTTP-header path and stdio-`initialize` path both covered.
- Webhook spec: rejects unsigned/bad-HMAC payloads before parsing.

---

## 14. Multi-platform adapter feasibility (researched 2026-07-27)

The core gem (`Portage::Ucp::Adapter`) is protocol-only — no Shopify-specific logic lives
outside `portage-ucp-shopify`. This section records what it'd take to add WooCommerce and
Wix adapters on the same contract, so the gem's pitch ("works with any commerce
platform") is backed by checked API research, not assumed. Verdicts below are from
official developer docs, not guesses — see citations.

### Shopify (existing adapter, baseline)

Fully agentic end-to-end: Storefront GraphQL Cart API for cart/checkout (Shopify has no
separate Checkout object — checkout is the same Cart, per `portage-ucp-shopify/lib/portage/ucp/
shopify/adapter.rb`), `cartPaymentUpdate` + `cartSubmitForCompletion` for server-to-server
payment-token completion, Admin GraphQL for catalog search and order lookup. Single
hosted platform, per-store subdomain + app-install access tokens. `link_identity` not
implemented — Shopify's Customer Account API is a separate OAuth story, out of scope for
the generic adapter (see `portage-ucp-shopify/lib/portage/ucp/shopify/adapter.rb`'s class comment).

### WooCommerce — verdict: FEASIBLE end-to-end

Two APIs used together:

- **Store API** (`/wp-json/wc/store/v1/...`) — headless, unauthenticated by design
  ([overview](https://developer.woocommerce.com/docs/apis/store-api/),
  [cart tokens](https://developer.woocommerce.com/docs/apis/store-api/cart-tokens/),
  [checkout](https://developer.woocommerce.com/docs/apis/store-api/resources-endpoints/checkout/)).
  Session identity carried via a `Cart-Token` header instead of cookies — built
  explicitly for headless use. Full server-side line-item CRUD
  (`add-item`/`remove-item`/`update-item`) maps directly to `create_cart`/`update_cart`/
  `cancel_cart`. `POST /checkout/:id` "attempts payment and returns the result," taking a
  gateway-specific `payment_data` array (e.g. Stripe's `stripe_source` token) — this maps
  to `complete_checkout(payment_token:)`, but the payload shape is gateway-dependent, so
  the adapter needs a per-gateway `payment_data` builder rather than one fixed shape.
- **REST API** (`wc/v3`, [reference](https://woocommerce.github.io/woocommerce-rest-api-docs/v3.html)) —
  HTTP Basic (Consumer Key/Secret) or one-legged OAuth 1.0a, generated per-store. `GET
  /products` and `GET /orders/<id>` map directly to `search_catalog`/`get_product`/
  `get_order`.

Gaps: no native customer-OAuth for third-party apps found in core WooCommerce docs —
`link_identity` would need a WordPress plugin (e.g. WP OAuth Server / JWT auth), not
something core WooCommerce provides. And **no central host**: WooCommerce is
self-hosted per-merchant WordPress, so unlike Shopify's `{shop}.myshopify.com` pattern,
the adapter's config must carry a per-store `base_url` plus per-store Consumer
Key/Secret (and know which payment gateway plugin is active, to shape `payment_data`).

### Wix — verdict: PARTIALLY FEASIBLE — checkout completion is blocked

Catalog ([Catalog V3](https://dev.wix.com/docs/api-reference/business-solutions/stores/catalog-v3/introduction)),
cart ([Cart object](https://dev.wix.com/docs/api-reference/business-solutions/e-commerce/purchase-flow/cart/cart-object)
— a genuine server-side headless resource, full CRUD, no cookie/session dependency), and
order lookup ([Orders API](https://dev.wix.com/docs/api-reference/business-solutions/e-commerce/orders/order-billing/introduction))
all map cleanly to `search_catalog`/`get_product`/`get_cart`/`create_cart`/`update_cart`/
`cancel_cart`/`get_order`. Identity has a real story too — OAuth2+PKCE for members
([setup guide](https://dev.wix.com/docs/go-headless/get-started/setup/authentication/create-an-oauth-app-for-visitors-and-members)) —
mapping reasonably to `link_identity(oauth_token:)`.

**But `complete_checkout(payment_token:)` cannot be implemented as a server-to-server
call.** Per Wix's own [headless redirect guide](https://dev.wix.com/docs/go-headless/project-guides/wix-hosted-pages/redirect-using-the-rest-api):
"To take advantage of Wix's checkout services, you need to redirect to a Wix-hosted
checkout page using the Redirects API... The response contains a single-use redirect
session URL in `redirectSession.fullUrl`... Redirect your visitor to the URL provided."
The one API that looks adjacent — [Create Order](https://dev.wix.com/docs/api-reference/business-solutions/e-commerce/orders/orders/create-order) —
is explicitly scoped to recording manual/external-system orders after the fact ("for
phone or email sales... For standard online purchases, orders are created automatically
through the checkout flow"), not processing a live charge. No documented API accepts a
third-party tokenized payment credential and marks a Wix order paid. This is inferred
from Wix's product architecture (their checkout UI is the only thing wired to process
payment), not a quoted contractual ban — flagging that distinction, not asserting it as
a stated policy.

Net effect: a Wix adapter can implement every UCP capability except a truly agentic
`complete_checkout` — that step would have to surface a redirect URL to the buyer and
poll/webhook for the resulting order, which isn't the same contract as Shopify/Woo's
server-to-server completion. Whether that's acceptable depends on whether UCP's spec has
a sanctioned redirect-based completion fallback; not something to paper over silently if
a Wix adapter is ever built.

### Cross-platform summary

| Capability | Shopify | WooCommerce | Wix |
|---|---|---|---|
| Catalog search/lookup | Admin GraphQL | REST API v3 (Consumer Key/Secret) | Catalog V3 (OAuth/API key) |
| Headless cart CRUD | Storefront GraphQL Cart | Store API + Cart-Token (no auth) | Cart object, full REST/SDK CRUD |
| Checkout creation | Same Cart object | Store API `/checkout` | eCommerce `Create Checkout` |
| **Payment-token completion** | **Yes** — `cartPaymentUpdate` + `cartSubmitForCompletion` | **Yes** — `POST /checkout/:id` w/ gateway `payment_data` | **No** — redirect to Wix-hosted checkout required |
| Order lookup | Admin GraphQL | REST API `wc/v3/orders/<id>` | Orders/Order Billing API |
| Identity OAuth | Not implemented (out of scope, separate API) | Not native (needs WP plugin) | Native OAuth2+PKCE for members |
| Connection model | Per-store subdomain + app-install token | Per-merchant WP base URL + Consumer Key/Secret (no central host) | Single hosted API, per-site OAuth app |

**Bottom line:** Shopify and WooCommerce adapters can both complete checkout fully
server-to-server. Wix cannot — its checkout step is redirect-only by design. Any
"works with any platform" claim in the gem's description should state this asymmetry
explicitly rather than imply uniform agentic checkout across all three.

### Target platform backlog (noted 2026-07-27, not yet researched)

User asked to record the platform list from
[Vercel's Next.js Commerce template gallery](https://vercel.com/templates/next.js/nextjs-commerce)
as the backlog of platforms this gem should eventually cover adapters for. Listed as
given, not yet cross-checked against feasibility the way Shopify/WooCommerce/Wix were
above:

- Shopify — **done**, existing adapter (`portage-ucp-shopify`).
- BigCommerce
- Ecwid by Lightspeed
- Geins
- Medusa
- Prodigy Commerce
- Saleor
- Shopware
- Swell
- Umbraco
- Wix — **researched above**, partially feasible (checkout redirect-only, see verdict
  above). Not yet built.
- Fourthwall

None of BigCommerce/Ecwid/Geins/Medusa/Prodigy/Saleor/Shopware/Swell/Umbraco/Fourthwall
have had their headless cart/checkout/payment-token/order APIs checked yet — treat any
assumption about their feasibility as unverified until researched the same way §14 did
for WooCommerce and Wix (official docs, cited, verdict per capability). WooCommerce was
researched in this same session but isn't on Vercel's list — keep it in the backlog
regardless, since it's already speced as feasible.

---


## 15. Buying without a URL (added 2026-08-07)

`portage buy <url>` assumes the shopper already knows the shop. The common case
doesn't: "buy me a snowboard" names a product, not a merchant. `portage find`
fills that gap, and URL-less `portage buy` runs it and then buys the picked
offer.

**Pipeline.** Search backends propose candidate URLs → collapse to origins, one
per host → `GET /.well-known/ucp` on each → search the survivors' catalogs →
merge and rank the offers (buyable stores first, then cheapest).

**Search backends use documented APIs, never a results page.** Parsing
`html.duckduckgo.com/html/?q=` or a Google SERP is the same class of ToS
violation §9 already refuses to commit against a merchant, and being scrupulous
about the shop while scraping the index would be incoherent. So: an allowlist
(`~/.portage/stores.yml` / `PORTAGE_STORES`), DuckDuckGo's Instant Answer API,
Brave's Search API, Google Programmable Search. Backends without credentials sit
out.

The cost of that rule is real and worth stating: the only keyless backend,
DuckDuckGo's Instant Answer API, answers *entity* queries rather than web
queries. `burton snowboards` resolves to burton.com; `snowboard` resolves to
nothing. Open-ended shopping needs a Brave or Google key. That's the honest
trade — narrow coverage by default rather than broad coverage by scraping.

**Probing is rate-limited and cached.** One request per candidate host,
throttled, capped at 12 candidates, with verdicts cached in
`~/.portage/discovery-cache.json` — misses for a day (the answer that changes
least and would be re-asked most), hits for six hours. A cached hit still
reconnects, since the next step needs a live session; only misses save work.
Without this, every search re-probes the same hosts and the CLI is a crawler.

**`--yes` cannot complete a purchase from a search result.** With a URL, the
shopper chose the merchant. Without one, a search ranker chose it, and blind-
buying the top-ranked offer from an unvetted host is how you end up owning a
counterfeit from a shop you've never heard of. So the merchant has to be named
by a person: either `--store`, or an interactive pick from the listed offers. A
piped or CI run with neither prints the offers and stops. This is the same
instinct as §9's refusal to mutate anonymously — the gate is on who chose, not
on what the flags say.

**Picked offers are bought by id.** `Buy` gained `--product-id`, and a picked
offer passes the product id straight through rather than re-running the catalog
search and hoping the ranking is stable. If the id isn't in the store's results,
nothing is bought — falling back to the top hit would buy something the shopper
never chose.

---

## 16. Post-purchase & shopper-agent backlog (added 2026-08-14)

Everything through §15 covers discovery-through-purchase. The gap on the other
side of `complete_checkout` — what the shopper's agent does *after* buying, and
around buying — is unresearched, same status as §14's platform list: recorded
as asked, not yet speced against real APIs. Grouped by where each lands in the
existing architecture:

**Order tracking & fulfillment**
- Shipment status/tracking number on an existing order — extends `get_order`
  (§3) rather than a new capability; Shopify/BigCommerce/WooCommerce all expose
  fulfillment/tracking data in their order APIs, unresearched which fields map
  cleanly.
- Where a platform doesn't expose tracking via its commerce API at all, a
  fallback path reading shipping-confirmation emails via an email MCP (e.g. the
  Gmail connector already in reach here) instead of a store adapter — client-
  side (`portage-ucp-client`) concern, not something a merchant's `Adapter`
  can back.
- Delivery-window notifications ("arriving soon" / "running late") need a poll
  or push loop against tracking state — either `portage-ucp-client` polling
  `get_order` on an interval, or wiring the carrier's own webhook into §11's
  order-lifecycle webhook handling. Push is preferable but carrier support
  varies; needs research per carrier before committing to either.
- Contacting the store's support — no adapter today models "open a support
  ticket" or "message the merchant." Would be a new capability
  (`dev.ucp.shopping.support`, contact/create-ticket actions) rather than a
  `get_order` extension; several platforms (Shopify, BigCommerce) don't expose
  this via their commerce APIs at all and would need a helpdesk integration
  (Zendesk/Gorgias) behind the adapter instead of the storefront API itself.

**Order changes**
- Cancelling an order and requesting a return/refund — the single biggest gap
  in this whole list. §11's order lifecycle only runs forward
  (`create → complete → fulfilled`); there's no `cancel_order`,
  `request_return`, or `refund` action anywhere in the `Adapter` contract.
  Every platform here (Shopify, BigCommerce, WooCommerce, Magento) has a real
  cancel/refund API; this isn't a feasibility question like reviews, it's a
  straightforward omission. Wants a `dev.ucp.shopping.order` extension
  (cancel/return/refund actions alongside the existing get) rather than a new
  top-level family, since it's the same resource as `get_order`.
- Stock/availability going stale between browsing and buying — `search_catalog`
  and `get_product` (§3) don't promise live inventory, and nothing re-checks
  stock right before `complete_checkout`. An adapter can complete a checkout
  for an item that sold out in between. Whether this is a new
  `check_availability` action or a required re-check inside `complete_checkout`
  itself is unresolved — leaning toward the latter, since a stale-stock
  failure belongs at the point of committing money, not as an extra call
  agents can forget to make.
- Digital goods delivery — `get_order` (§3) returns a `permalink_url`; nothing
  models handing back a download link or license key for non-physical
  products. The Etsy/Instagram adapters already surface a narrower version of
  this problem ("checkout is redirect-link only," §14) — full digital delivery
  is the same shape of gap, just unaddressed for platforms that do support a
  real checkout.

**Pricing**
- Discount/coupon codes at checkout — `create_checkout`/`create_cart` (§3)
  gaining an `discount_code:` param, applied by the adapter against the
  platform's own discount API (Shopify has one, WooCommerce/BigCommerce need
  checking). Distinct from `portage-ucp-shopify`'s existing merchant-side
  `create-discount` tool, which authors codes rather than redeeming them.
- "Is this the best price available" — not a single-store capability at all;
  it's `portage find`'s (§15) multi-store ranking applied to a product the
  shopper already has, not one they're searching for. Needs a "find this same
  item elsewhere" mode rather than new `Adapter` methods.
- Gift cards / store credit — adjacent to discount codes but a distinct
  payment-adjacent primitive (a balance that partially funds a checkout,
  rather than a code that adjusts a price), so it likely wants its own
  `gift_card_balance:`/apply param on checkout rather than being folded into
  `discount_code:`.

**Reviews**
- Leaving a product/order review post-purchase — no capability family for this
  either; would need a `dev.ucp.shopping.review` family (submit/edit, scoped to
  a completed order so an agent can't review something never bought). Shopify
  has no first-party review API (relies on apps like Judge.me/Yotpo/Loox —
  adapter would need to target one of those, unresearched which); WooCommerce
  reviews are native (WP comments API), BigCommerce has a native Reviews API.
  Per-platform feasibility unchecked, same as everything else in this section.

**Subscriptions & payment**
- Subscription listing/cancellation and billing-date tracking — no capability
  family exists for recurring orders today; `Adapter`'s catalog/cart/checkout/
  order/identity split (§3) has nowhere for this to live without a new
  `dev.ucp.shopping.subscription` family. Shopify Subscriptions, Recharge, and
  WooCommerce Subscriptions all model this differently — unresearched which
  can back a common contract versus needing per-platform escape hatches.
- Multiple payment methods per checkout — `complete_checkout`'s `payment_token`
  (§9) is already handler-agnostic in principle (any AP2/UCP payment handler
  token), so this may already be "just" a client-side UX question — letting
  the shopper pick which tokenized handler to use — rather than a gem change.
  Needs confirming against a real multi-handler flow before assuming so.
- Crypto payment support — same boundary as above: `payment_token` doesn't
  care what funded it, so a crypto-backed UCP/AP2 payment handler should flow
  through unchanged *if* one exists and produces a compliant token. No such
  handler has been checked; this is a "does the ecosystem have one" research
  item, not a gem-side one.
- Saving a payment method for reuse — this is the one item here that directly
  presses on §9's boundary rather than sitting comfortably inside it.
  `payment_token` is documented as **single-use**; "save it and reuse it"
  either means something different (a PSP-issued *reference* — Stripe's saved
  PaymentMethod id, a card-network token vault id — that gets exchanged for a
  fresh single-use `payment_token` at each `complete_checkout`) or it means
  reusing the same token twice, which §9 already forbids and no adapter should
  be made to do. The gem stores only the opaque reference, never the
  underlying credential — same posture as manifest signing (§7/§9: "never
  generates/stores keys implicitly"), extended to payment references. This
  only works at all if the shopper has a persistent identity to hang the
  reference off of, which is what `Adapter`'s existing identity-linking
  methods (§3) are for — OAuth here means linking the shopper's identity with
  the merchant/PSP once, not re-authenticating per purchase. Concretely this
  wants a `dev.ucp.shopping.payment_method` family (list/save/delete a
  reference, scoped to a linked identity) plus a hard rule that
  `save_payment_method` never accepts anything that looks like raw card data —
  the existing `PaymentTokenGuard` Luhn/format check (§9) should run here too,
  not just on `complete_checkout`. Deletion/revocation needs to be a first-
  class action, not an afterthought — a saved reference is a standing liability
  the single-use token never was, and rate limiting on lookups against it
  matters more here than anywhere else in the gem.
- Saving a shipping address for reuse — same shape as the payment-method item
  directly above (opaque reference, scoped to a linked identity, deletion as
  a first-class action), and the two should ship together or not at all: a
  reusable payment reference with no reusable address just re-prompts for
  address every time, which defeats half the point of "save for reuse." No
  PCI-style boundary here, but it's still PII at rest, so the same never-
  generates/stores-secrets-implicitly posture applies to whatever encrypts it.

**Privacy & data lifecycle**
- Once the gem persists *anything* tied to a shopper — the payment-method and
  address references above, plus the identity-linking `Adapter` methods (§3)
  that already exist — it takes on a GDPR/CCPA right-to-erasure obligation it
  didn't have while everything in scope was a single-use token. There is
  currently no `delete_shopper_data` capability to discharge that obligation.
  This should land in the same roadmap step as saved payment methods/addresses
  (§8 revised ordering: security is foundation, not retrofit) rather than
  after — shipping persistence without a deletion path is the mistake to
  avoid, not a follow-up to fix later.

None of the above is scoped or estimated — recorded so it doesn't get lost, in
the same spirit as §14's platform list, not as a commitment to build any of it
next.

---

## 17. Adapter conformance kit (added 2026-08-20)

Every item in §16 is a shopper-facing capability gap. This one isn't — it's a
process gap, and arguably a more urgent one given who this gem is actually
for. The README says the real audience is third-party adapter authors, not
the shipped adapters; §7's adapter-contract-evolution decision (default-raise,
advertise-if-overridden) makes it *easy* for a third-party `Adapter` subclass
to compile and run while silently satisfying the contract wrong — a capability
that's advertised but returns malformed data, breaks idempotency, or leaks a
`payment_token` into a log line the subclass author wrote, not the gem.

Nothing currently checks a third-party `Adapter` against the contract before
its capability shows up in a manifest. `Portage::Ucp::SchemaValidator` (see
README, "Spec conformance") validates *wire output* against UCP's schemas, but
that's necessary, not sufficient — schema-valid output can still violate §9
(idempotency not actually deduped, a PAN slipping past a hand-rolled guard
that isn't the shared `PaymentTokenGuard`) or lie about what it fulfilled. A
conformance kit — a shared rspec/shared-examples suite an adapter author runs
against their own `Adapter` instance, covering the contract's behavioral
guarantees (not just its JSON Schema shape) — is the missing piece that turns
"any backend that implements `Adapter`" from a README claim into something
checked. Unscoped; noted here because it's easy to miss when every other gap
in this log is a capability, not a test suite.

**Built (2026-08-27):** `Portage::Ucp::RSpec` (`lib/portage/ucp/rspec.rb`) —
an `it_behaves_like "a portage adapter"` shared-examples suite covering
exactly the three failure modes named above: idempotency dedup (repeat
`create_checkout` with the same key, assert identical output), the PAN guard
(assert a Luhn-valid raw card number never reaches the adapter's
`complete_checkout` — this is a `Dispatcher`-level guarantee, not an
`Adapter`-level one, so the kit routes every call through a real `Dispatcher`
rather than calling the adapter directly, the same as a real MCP client
would), and wire conformance (validate `create_checkout`'s output against
`schemas/shopping/checkout.json` via the existing `SchemaValidator`). An
`OutOfStockError` example is opt-in (`let(:out_of_stock_product_id)`) since
not every adapter's test double can represent a sold-out line on demand.

Ships alongside `Portage::Ucp::ReferenceAdapter` (`lib/portage/ucp/
reference_adapter.rb`) — the in-memory adapter roadmap §8 step 1 called for
and this section's own first paragraph didn't have: `spec/support/
fake_adapter.rb` proved the protocol layer in the core gem's own specs since
early on, but stayed test-only and catalog/cart/checkout/order only.
`ReferenceAdapter` is the shipped, documented version — every capability
including `discount_codes_supported?`/`fulfillment_supported?`/
`link_identity` (the first adapter in this repo to back identity linking at
all) — and doubles as the kit's own fixture
(`spec/reference_adapter_conformance_spec.rb` runs the kit against it, so the
kit is exercised by CI, not just documented). `spec/support/fake_adapter.rb`
is left as-is rather than merged into it — narrower, purpose-built for the
core gem's own specs' existing expectations, and touching seven spec files'
worth of assumptions to de-duplicate two similar-shaped adapters wasn't this
pass's job.

**Wired (2026-08-27):** all seven adapter gems now run the kit against their
real `Adapter` through a real `Dispatcher` —
`spec/portage/ucp/<platform>/conformance_spec.rb` in each. Every one is
green, and the fixture each needs turned out to be one canned response (two
for BigCommerce/WooCommerce/Magento, whose `create_checkout` reads back what
it wrote), because the kit's reachable surface is narrower than the handoff
note in this section's previous revision assumed: the repeat-call example is answered from
`Support::Idempotency`'s in-process table without a second HTTP call, and the
PAN example is rejected by `PaymentTokenGuard` inside `Dispatcher` before
`complete_checkout` runs at all. So no `cartPaymentUpdate`/
`cartSubmitForCompletion` sequence is ever fired, and no body-matching stubs
were needed. The handoff's step 3 was solving a problem the kit doesn't have.

What it *did* have was the failure mode step 3 was worried about, one level
up: the dedup example compared the two calls' output for equality, and a
fixed-response test double returns identical output whether or not the
adapter deduped anything — so the example would have passed for the wrong
reason on exactly the webmock setup every adapter author writes. Fixed in the
kit rather than worked around in each spec: when the adapter includes
`Support::Idempotency` (all seven do, and so does `ReferenceAdapter`), the
example now also asserts the key landed in the dedup table, which an adapter
that never deduped has no entry in. Verified against a deliberately
non-deduping `ReferenceAdapter` subclass that returns a constant checkout —
red on the table assertion, green before the fix. An adapter that dedupes
some other way gets a `warn` telling it to assert dedup itself, not a silent
pass.

Etsy and Instagram are worth calling out: they advertise checkout (both
override `create_checkout`/`get_checkout`) even though their checkout is a
redirect link, so the kit's checkout examples *run* there rather than
skipping — including the PAN example, which passes because the guard rejects
the token, not because their `complete_checkout` raises
`NotImplementedError`. That was the thing step 5 said to confirm rather than
trust.

**Still not built:** the kit has no discount or fulfillment examples, so
wiring it did *not* make the §18/§19 Shopify-only parity gap fail anywhere —
capability advertisement is checked, capability *behavior* isn't. Two
examples gated on `discount_codes_supported?`/`fulfillment_supported?` (they
would self-skip on the other six and run on Shopify + `ReferenceAdapter`) are
the next piece, and the honest version of the claim that this kit enforces
parity. Also unbuilt: enabling the opt-in `out_of_stock_product_id` example
per adapter — that one *does* reach `complete_checkout`, so it's the case
that genuinely needs stubs matching on request body.

**Handoff update (2026-08-27) — a live test store is now available, step 3's
decision changed:**

A real Shopify dev store (`ucp-test-bc2vif1p.myshopify.com`) is set up with
working credentials in the repo-root `.env` (`SHOPIFY_SHOP_DOMAIN`,
`SHOPIFY_ADMIN_ACCESS_TOKEN`, `SHOPIFY_STOREFRONT_ACCESS_TOKEN`,
`SHOPIFY_CLIENT_ID`/`SHOPIFY_CLIENT_SECRET`), verified live against the Admin
API. This makes step 3's stub-vs-fake-client choice moot for a first pass:
point `conformance_spec.rb`'s `Client.new(...)` at the real store via `ENV`
instead of webmock, and the three sequential GraphQL mutations
(`cartCreate` → `cartPaymentUpdate` → `cartSubmitForCompletion`) just get real
responses in order — no body-matching stubs or fake in-order client needed.
`existing_product_id: "gid://shopify/Product/8379425259567"` ("The Minimal
Snowboard", 50 in stock, `availableForSale: true`) is a known-good candidate
already confirmed via a live Admin API query.

Caveats for whoever picks this up:

- `spec_helper.rb` currently has `WebMock.disable_net_connect!` — a live-store
  conformance spec needs that host allowed (`WebMock.disable_net_connect!
  (allow: "ucp-test-bc2vif1p.myshopify.com")`) or the live spec split into its
  own helper/tag so the rest of the suite stays hermetic. Decide which before
  writing the spec — same "decide before, not mid-write" rule as step 3
  originally called out.
- The Admin token is **not static** — it's fetched via
  `Portage::Ucp::Shopify::AccessTokenFetcher` (OAuth `client_credentials`
  grant against `client_id`/`client_secret`; see README "Fetching an Admin
  token from a custom app's client credentials") and expires in ~24h
  (`rake shopify_access_token` regenerates it). A CI run of a live-store spec
  needs either a fresh token fetched at run time or this to stay a
  local/manual-only spec — don't assume the current `.env` token is still
  valid by the time this is picked up.
- Local toolchain note, not store-related: this repo's `.mise.toml` pins
  ruby 3.4.9, and `bundle install` under it failed two different ways before
  it worked — (1) json 2.21.1/2.21.2 doesn't compile against ruby 3.4's
  headers (`rb_hash_bulk_insert`/`rb_str_to_interned_str` redeclared static);
  fixed by pinning `gem "json", "2.18.1"` in `portage-ucp-shopify/Gemfile`.
  (2) the mise-installed ruby 3.4.9 had resolved to an x86_64 (Rosetta) build
  on an arm64 Mac, cross-contaminating native exts with the arm64 ruby on
  PATH (`bigdecimal.bundle ... incompatible architecture`); fixed by
  `mise uninstall ruby@3.4.9 && mise install ruby@3.4.9` to get a native arm64
  build, then a fresh `bundle install`. If `bundle exec rspec` throws a
  LoadError mentioning architecture, check `mise exec -- ruby -v`'s platform
  suffix before chasing anything gem-level. Separately, `bundle exec` under
  the *bare* `ruby`/`bundle` on PATH resolves to a different, un-pinned mise
  ruby (3.3.9) than the one `.mise.toml` asks for — always run specs via
  `mise exec -- bundle exec rspec`, not `bundle exec rspec` alone, or it
  silently loads against gems that were never installed for that Ruby.

**Wired and green (2026-08-27):** `portage-ucp-shopify/spec/portage/ucp/
shopify/conformance_spec.rb` runs the kit against the live store per the
plan above (`WebMock.disable_net_connect!(allow: shop_domain)` scoped to
this file's own `around` block, `.env` sourced manually since neither this
repo nor the adapter gem carries a dotenv dependency; every example
self-skips when `SHOPIFY_SHOP_DOMAIN` is absent, so a checkout with no live
store configured still passes). `bundle exec rspec.rb`'s prediction from the
original handoff held — it caught four real bugs, none of them webmock's
fixed-response-body limitation, all of them "the real API doesn't return
what our stubs pretended it would":

1. **`ProductVariant#price`/`#compareAtPrice` are the bare `Money` scalar**
   (a decimal string), not a `MoneyV2` object — Admin API 2026-04 rejects
   `{ amount currencyCode }` sub-selections on them. `Mapper#variant` now
   takes the product's own currency (from `priceRange`, shared by every
   variant) and builds the `Price` from the scalar directly
   (`Mapper.scalar_price`).
2. **`ProductCompareAtPriceRange`'s fields are `minVariantCompareAtPrice`/
   `maxVariantCompareAtPrice`**, not `minVariantPrice`/`maxVariantPrice`
   (those names are `ProductPriceRangeV2`-only, and were copy-pasted onto
   the compare-at query and mapper).
3. **Storefront's `Cart#deliveryGroups` is a paginated connection**
   (`CartDeliveryGroupConnection`, needs `(first: N) { nodes { ... } }`),
   not a bare list — `queries.rb` and `Mapper#checkout_fulfillment` both
   assumed the latter (§19 confirmed the *mutation* shapes live but never
   actually exercised a cart with delivery groups against the query shape).
4. **`Cart#cost.totalTaxAmount` is nullable** — a fresh cart with no
   shipping address/tax context returns `null`, not a zeroed `MoneyV2`;
   `Mapper#totals` crashed on it (`nil["amount"]`) rather than treating
   absent tax as zero (which `Support::Totals.summary` already handles
   correctly once given an actual `0`).

None of these were catchable by `adapter_spec.rb`'s hand-rolled webmock
fixtures, which fabricate response shapes by hand — they're exactly the
"schema-valid-looking test double, wrong-shaped real API" gap §17 exists to
close. Every affected fixture (`adapter_spec.rb`, `mapper_spec.rb`) updated
to match the real shapes; a new `mapper_spec.rb` case locks in the null-tax
handling.

**A fifth thing surfaced that isn't a bug, but is a real conformance-kit
gap:** the kit passed one `existing_product_id` to every example, but
Shopify genuinely needs two different ids for "the same" item —
`get_product`/`search_catalog` go through the Admin API's `Product` node,
while `create_checkout`'s `cart_lines` feeds straight into Storefront's
`CartLineInput#merchandiseId`, a `ProductVariant` GID (see `Mapper`'s
top-of-file note — this was already known, just never exercised against a
real store end-to-end). Fixed by giving the kit itself
(`Portage::Ucp::RSpec`, `lib/portage/ucp/rspec.rb`) an `existing_variant_id`
let that defaults to `existing_product_id` — a no-op for every other
adapter, where the two are the same id — and threading it through the
checkout-side examples instead of `existing_product_id`. Shopify's
conformance spec sets both explicitly (`gid://shopify/Product/...` /
`gid://shopify/ProductVariant/...`).

**Still not built:** the other six adapters (step 5 of the original
handoff) — Wix/WooCommerce/BigCommerce/Magento (cart+checkout+order only)
and Etsy/Instagram (no checkout capability advertised at all). None of them
have a live test store the way Shopify now does, so each would need either
its own sandbox credentials or a decision to run the kit against webmock
stubs there instead (accepting the "passes for the wrong reason" risk
this section originally flagged for Shopify, now resolved for Shopify only).

---

## 18. Discount codes (added 2026-08-20)

Next §16 item picked up after order cancel/return/refund and the checkout
stock re-check: "Discount/coupon codes at checkout." Digital goods delivery
(the item listed just above it in §16) was considered first and rejected —
checked every vendored schema type a line item or order could plausibly carry
one on (`order_line_item.json`, `item.json`, `order_confirmation.json`) and
none has a download-link/license-key field or an `additionalProperties`
opening for one. Shopify itself has no native field either (digital delivery
there is entirely app-mediated). Building it now would mean inventing
non-spec wire data, which cuts against the whole point of vendoring UCP's own
schemas (§1) — that item stays parked in §16 until UCP's spec actually grows
a field for it.

Discount codes, by contrast, already have a full vendored extension schema —
`schemas/shopping/discount.json`, `dev.ucp.shopping.discount` — that extends
Cart and Checkout with a `discounts: {codes, applied}` field rather than
adding new top-level actions. That's a shape this gem hadn't needed before:
every existing capability (`capabilities/*.rb`) is a flat action-name → method
map, and `Capability#advertised_for?` only knows how to ask "is at least one
of these backing methods overridden?" A capability with no actions of its own
would never advertise under that check (`actions.values.any?` on an empty
hash is always `false`).

Rather than build out real `extends`/manifest-nesting machinery — the
capability model doesn't have one yet, manifest.rb doesn't even emit spec/
schema URLs for the capabilities that already exist, and inventing that
infrastructure for one capability is exactly the kind of speculative
generality this project tries to avoid — `Capability` gained a minimal
`predicate:` option: an extension capability can name an adapter method
(`Adapter#discount_codes_supported?`, default `false`) that `advertised_for?`
asks directly instead of inspecting `actions`. `dev.ucp.shopping.discount`
carries `actions: {}` and `predicate: :discount_codes_supported?`. This is the
smallest change that makes a field-only extension capability negotiable at
all; a real "extends" concept (spec/schema URLs, nested nesting in the
manifest) is still not built and should be designed properly if a second
field-only extension ever needs one, not extrapolated from this one example.

`create_cart`/`update_cart`/`create_checkout`/`update_checkout` all gained an
optional `discount_codes:` param, defaulting to `nil` — deliberately not `[]`,
so "the request didn't mention discounts" and "the request wants discounts
cleared" stay distinguishable at the Ruby layer the same way the wire schema
distinguishes "omitted" from "explicit empty array." Only the Shopify adapter
implements it (Storefront `CartInput.discountCodes` on create,
`cartDiscountCodesUpdate` on update, same full-replacement posture as
`update_cart`'s existing line-item handling) — BigCommerce/WooCommerce/
Magento/Wix/Etsy/Instagram are untouched, same incremental-by-adapter pattern
order cancel/refund already established. `AppliedDiscount#allocations` (the
per-target JSONPath breakdown) is left unpopulated by the Shopify mapper —
Storefront's `discountAllocations` doesn't cleanly resolve to a specific line
item index without a second per-line query this pass didn't add; noted here
rather than guessed at.

---

## 19. Fulfillment / shipping-option selection (added 2026-08-20)

Next capability gap picked up after order cancel/return/refund: letting an
agent pick a shipping rate or pickup location during checkout. Same shape of
problem discount codes solved — `schemas/shopping/fulfillment.json`
(`dev.ucp.shopping.fulfillment`) is a full vendored extension schema that
extends Checkout with a `fulfillment` field rather than new top-level
actions, so it reuses `Capability`'s `predicate:` option
(`Adapter#fulfillment_supported?`, default `false`) the same way
`dev.ucp.shopping.discount` does.

The extension is more structurally involved than discount codes, though:
`fulfillment.methods[]` covers both shipping and pickup, each method can
carry multiple merchant-generated destinations (addresses/retail locations)
and groups (packages), and each group carries its own list of priced
`FulfillmentOption`s the agent chooses from via `selected_option_id`. That
required five new value objects beyond the container itself
(`PostalAddress`, `ShippingDestination`, `RetailLocation`,
`FulfillmentOption`, `FulfillmentGroup`, `FulfillmentMethod`) — this gem had
no address type at all before this, despite `types/postal_address.json`
existing in the vendored schemas since day one; nothing had needed it yet.

Naming collision to flag: the extension's container type is called
`fulfillment` in the schema, same as `Order#fulfillment` (the *post-purchase*
delivery-tracking container — expectations/events, already modeled as
`Portage::Ucp::Fulfillment`). These are genuinely different things at
different points in the lifecycle — one is "which shipping method do you
want," the other is "here's what shipped and when" — so the new container is
`Portage::Ucp::CheckoutFulfillment`, not a second `Fulfillment`. Its
`methods` field is `shipping_methods` internally (a bare `:methods`
Data.define member shadows `Kernel#methods`); `to_wire_h` maps it back to the
spec's `"methods"` key, same “internal name diverges from wire key” pattern
`AppliedDiscount#allocation_method` → `"method"` already established.

`create_checkout`/`update_checkout` both gained an optional `fulfillment:`
param, `nil` by default — same omitted-vs-explicit distinction the
`discount_codes:` param made, though what a non-nil value *means* differs by
direction: on create it's the agent's requested method types plus which line
items go where (the merchant fills in destinations/groups/options in the
response); on update it's the agent's `selected_destination_id`/
`selected_option_id` choices against what the merchant already offered.
`create_cart`/`update_cart` did **not** gain the param — Cart's schema has no
fulfillment extension point; shipping selection is checkout-only in the
vendored spec, unlike discounts which apply to both.

Shopify's mapping landed as its own follow-up commit, matching how discount
codes' contract and Shopify-implementation split. Storefront's Cart has no
"fulfillment method" concept above `deliveryGroups`, so the adapter
synthesizes exactly one `FulfillmentMethod` per checkout and maps each
Shopify deliveryGroup onto a `FulfillmentGroup` underneath it — a cart also
only ever carries the one buyer-submitted address, so `destinations` is
always `[]` or a single entry with a fixed id (`"current"`), never a real
list to choose between. The agent's address goes out via
`cartDeliveryAddressesAdd`, its `selected_option_id` choices via
`cartSelectedDeliveryOptionsUpdate` — both mutations' input shapes were
confirmed live against a real dev store (`ucp-test-bc2vif1p.myshopify.com`,
2026-08-21): cart created, address submitted via
`{ address: { deliveryAddress: {...} }, selected: true }`, delivery groups
came back populated with priced options, and the selection round-tripped via
`{ deliveryGroupId:, deliveryOptionHandle: }` with `selectedDeliveryOption`
reflecting the chosen handle. No shape changes needed. `cartPaymentUpdate`'s
`paymentMethod` sub-shape is still unconfirmed (roadmap step 5).

---

## 20. Catalog conformance (added 2026-08-27)

Auditing whether `search_catalog`/`get_product` actually round-trip through
UCP's own catalog schemas (`catalog_search.json`, `catalog_lookup.json`) —
the same conformance-gate posture §17 established for checkout — found they
didn't come close. `Product` had no `to_wire_h` at all: the dispatcher's
`wrap` (§5) only merges the `ucp` envelope onto a value object's own wire
hash, so a return value with no `to_wire_h` fell straight into the
"unstructured" fallback branch and was never schema-checked by anything.
Underneath that, the shape itself didn't match the spec — `Product` carried
a single `price`/`available` pair with `variants` as bare hashes, where
`types/product.json` requires `price_range` and `variants` (minItems: 1) of
real `types/variant.json` objects, and neither `search_catalog` nor
`get_product` wrapped their result in the required `{ucp, products}` /
`{ucp, product}` container at all (a bare array/Product doesn't validate
against `search_response`/`get_product_response`).

This mattered beyond spec purity: `types/variant.json` already models GS1
barcodes (`barcodes[]`), structured Size/Color axes (`options`/
`selectedOptions`), a `sku`, and both `plain`/`html` description formats,
and `product.json`/`variant.json` both carry a `metadata` field the spec
itself names as "business-defined custom data extending the standard
model" — every structured-attribute gap a business would actually hit
(GTINs, metafields, real option axes instead of an HTML blob) already had a
sanctioned home in the vendored spec. The gem just wasn't populating it.

**Fix, in order:**
1. New value objects — `Price`/`PriceRange` (the wire-shape counterpart to
   the arithmetic-only `Money`), `Description`, `Category`, `Media`,
   `OptionValue`/`ProductOption`/`SelectedOption`, `Rating`, and a real
   `Variant` — plus rewritten `Product`, both with `to_wire_h`. `barcodes`
   and `availability` stay plain wire-shaped hashes rather than their own
   Data types, same posture as `Adjustment#line_items`' inline hashes —
   the spec doesn't name them as standalone `$ref`s either.
2. `CatalogSearchResult` (`{products, messages}`) and `ProductDetail`
   (`{product}`) — the containers `search_catalog`/`get_product` actually
   need to return for `WireEnvelope.wrap` to produce a conformant
   `search_response`/`get_product_response`. Added a `dev.ucp.shopping.catalog`
   entry to `WireEnvelope::ENVELOPES` to match. `ProductDetail` doesn't
   model `catalog_lookup.json`'s `detail_product` extension (`selected`/
   `options` availability signals for interactive variant narrowing) —
   `Adapter#get_product`'s signature has no `selected:`/`preferences:`
   params to source it from yet; unresearched, same backlog posture as §16.
3. `SchemaValidator#errors_for` gained fragment support
   (`"path/to.json#/$defs/name"`) — `catalog_search.json`/
   `catalog_lookup.json` define several request/response shapes as sibling
   `$defs` rather than one schema per file, unlike `checkout.json`'s flat
   top-level shape. Resolves through the same `ref_resolver` every other
   cross-document `$ref` in these vendored schemas already uses, so a
   `$defs` entry `$ref`-ing a sibling `$defs` entry (`get_product_response`
   -> `detail_product`) still resolves correctly.
4. Two new conformance-kit examples (§17) validate `search_catalog`/
   `get_product` output against `search_response`/`get_product_response`,
   skipping when `dev.ucp.shopping.catalog` isn't advertised — same pattern
   as the existing `create_checkout` example.
5. Shopify: extended `PRODUCT_FIELDS` with `handle`/`tags`/`descriptionHtml`/
   `options`/`compareAtPriceRange` and each variant's `sku`/`barcode`/
   `selectedOptions`/`image`/`compareAtPrice` — all standard Storefront/Admin
   fields, no metafield config needed for GTINs or option axes. `barcode` is
   a single untyped Shopify string with no declared GS1 sub-standard;
   inferred from length (8/12/13 -> EAN/UPC/EAN-13) rather than asserted,
   falling back to bare `"GTIN"` for anything else rather than dropping the
   value. `ProductVariant` has no description field of its own — reuses the
   parent product's `Description`, same fallback shape as Wix's variant
   title falling back to the product's below.
6. Wix: V1 Catalog's `productOptions`/`choices` map onto `ProductOption`/
   `OptionValue`; `media.mainMedia` onto `Media`. A single-SKU product (no
   options) has no `variants` array in V1 at all — `product_variants`
   synthesizes one straight from the product-level fields, since
   `types/product.json` requires at least one. No barcode/GTIN field found
   in V1 Catalog's documented schema — left unmapped rather than guessed at,
   unresearched whether V3 exposes one.

**Deliberately not done:** the merchant-defined-metadata config DSL
(`Portage::Ucp::Shopify.configure { |c| c.metadata_field :color_hex,
metafield: "custom.color_code" } }`) that motivated this pass in the first
place. `Product#metadata`/`Variant#metadata` now exist as the wire target,
but nothing populates them yet — Shopify's `metafields(identifiers:)` can't
fetch-all, so populating them needs a per-adapter config surface (deferred,
not core-`Configuration`, per `mapper.rb`'s "nothing Shopify-shaped leaks
past this file") telling the query which metafields to ask for and how to
parse each one's `type` (string/json/dimension/measurement/...). Follow-up,
not blocked by anything above.

**Handoff — the metadata_field config DSL (do this next):**

1. New `Portage::Ucp::Shopify::Configuration` + `Portage::Ucp::Shopify.configure`/
   `.configuration` singleton (`portage-ucp-shopify/lib/portage/ucp/shopify/
   configuration.rb`, required from `shopify.rb` after `require_relative
   "shopify/version"`), mirroring core's own `Portage::Ucp::Configuration`
   pattern (`portage-ucp/lib/portage/ucp/configuration.rb`) exactly — a
   `@configuration ||= Configuration.new` memo, `configure { |c| yield }`.
   Don't touch core `Configuration` itself for this — it's already documented
   as adapter-agnostic (`registry`/`authenticator`/`rate_limiter`/...), and
   `Portage::Ucp::Shopify.configuration.metadata_fields` living on the
   Shopify-specific singleton is what keeps `mapper.rb`'s "nothing
   Shopify-shaped leaks past this file" posture intact — a Wix/WooCommerce
   consumer configuring their own adapter shouldn't see Shopify's config
   surface at all.
2. `metadata_field(key, metafield:)` appends `{key: key, namespace:,
   key: <metafield-part>}` (split `"custom.color_code"` on the first `.`) to
   an array on `Configuration`. Product-level and variant-level metafields
   need to be distinguishable — Shopify's Admin API exposes
   `metafields(identifiers:)` on both `Product` and `ProductVariant` as
   *separate* fields with separate cost, and a real catalog (this design-log's
   own examples — `color_hex` naturally varies per variant, `fabric_content`
   is usually product-wide) needs both. Decide the DSL shape for that split
   before writing code — e.g. `c.metadata_field :color_hex, from_variant_metafield:
   "custom.color_code"` vs a shared `metadata_field` with a `scope:` kwarg —
   don't discover it mid-implementation.
3. **The hard part:** `PRODUCT_FIELDS` (`portage-ucp-shopify/lib/portage/ucp/
   shopify/queries.rb`) is a `.freeze`'d constant built once at load time —
   `SEARCH_CATALOG`/`GET_PRODUCT` interpolate it the same way. Configured
   metafield identifiers aren't known until `Portage::Ucp::Shopify.configure`
   runs, which happens after the gem loads, so the metafields fragment
   (`metafields(identifiers: [{namespace: "custom", key: "color_code"}, ...])
   { key value type }`) can't live in the frozen constant — it has to be
   built per-call from `Portage::Ucp::Shopify.configuration.metadata_fields`
   and spliced into the query string (or built as a separate query fragment
   method `Queries.metafields_fragment(scope:)` that `Mapper`/`Client` compose
   at call time). Get this wrong and metafields configured after the first
   query silently never show up — worth a spec that configures
   `metadata_field` *after* requiring the gem (matching how a real consumer's
   own `config/initializers` would run) and asserts the sent GraphQL body
   actually contains the identifier, not just that the mapped output looks
   right against a hand-built fixture.
4. Shopify's `metafields(identifiers:)` response node is `{key, namespace,
   value, type}` — `type` is one of Shopify's ~20 metafield types
   (`single_line_text_field`, `json`, `dimension`, `measurement`,
   `number_decimal`, `list.single_line_text_field`, ...), each with a
   different value encoding (JSON needs `JSON.parse`; `dimension`/
   `measurement` are `{"value":..,"unit":..}` JSON strings; list types are
   JSON arrays of the scalar type). Decide up front how much of that table to
   actually parse vs. pass the raw string through — parsing every type is a
   real chunk of work on its own and probably isn't worth blocking the first
   version of this feature on. A reasonable first cut: parse `json`/
   `list.*`/`dimension`/`measurement` (the four where "raw string" would be
   actively wrong for an agent to consume), pass every other type through as
   the bare string.
5. Cost budget: each `identifiers:` entry adds to the query's GraphQL cost:
   Shopify caps `metafields(identifiers:)` at 250 identifiers per call.
   Nothing in this gem enforces that today (no configured metafields exist
   yet) — add a guard (raise, or truncate-and-warn) in
   `Portage::Ucp::Shopify::Configuration#metadata_field` or at query-build
   time once #3 lands, so a merchant with a long attribute list gets a clear
   error instead of a confusing GraphQL cost-limit rejection from Shopify
   itself.
6. Once product-level metafields work end to end (config -> query -> parsed
   value -> `Product#metadata`), repeat for variant-level onto
   `Variant#metadata` — same mechanism, different GraphQL field
   (`ProductVariant.metafields`), and confirm both can be configured
   independently per the DSL decision in step 2.
7. Not scoped here at all: Wix. V1 Catalog's REST product/variant shape has
   no documented metafields-equivalent extension point (Wix's closest analog
   is "custom fields" on V3, unresearched) — leave `Portage::Ucp::Shopify.configure`
   Shopify-only for now rather than trying to generalize the DSL across
   adapters before a second real backend proves out the shape.

## 21. The metadata_field config DSL, built (2026-08-27)

Did the §20 handoff, steps 1-6 (step 7, Wix, stays out of scope).

`Portage::Ucp::Shopify::Configuration` (`portage-ucp-shopify/lib/portage/ucp/
shopify/configuration.rb`) mirrors core's `Configuration` singleton pattern —
`Shopify.configure { |c| ... }` / `Shopify.configuration`, required from
`shopify.rb` right after `shopify/version`. `metadata_field(key, metafield:,
scope: :product)` splits `"custom.color_code"` on the first `.` and files the
entry onto a product- or variant-scoped array (`scope:` defaults to
`:product`) — the DSL-shape question from handoff step 2 resolved as a kwarg
rather than two separate method names (`from_variant_metafield:` etc.), since
both scopes share every other bit of validation (namespace-split, the
250-identifier cap) and a kwarg keeps that one code path. Raises
`InvalidMetadataField` past Shopify's 250-identifier `metafields(identifiers:)`
cap (handoff step 5) or an unrecognized `scope:`.

The frozen-constant problem (handoff step 3, "the hard part"): `PRODUCT_FIELDS`
became `PRODUCT_FIELDS_TEMPLATE`, still frozen, but now carries
`%<product_metafields>s`/`%<variant_metafields>s` placeholders that
`Queries.product_fields` fills via `format` on every call by reading
`Shopify.configuration.fields_for(scope)` fresh each time — so a query built
before `configure` runs and one built after differ, which is exactly what a
config-DSL surface needs (specced directly: `search_catalog_query` called
before and after `configure`, asserting the fragment only appears in the
second). `SEARCH_CATALOG`/`GET_PRODUCT` constants became
`Queries.search_catalog_query`/`.product_by_id_query` methods for the same
reason (`get_product_query` renamed to dodge `Naming/AccessorMethodName`) —
`Adapter#search_catalog`/`#get_product` call sites updated to match.

`Mapper#metafields_metadata` zips `Shopify.configuration.fields_for(scope)`
against Shopify's `metafields(identifiers:)` response array positionally
(same order the query requested them in) to build `Product#metadata`/
`Variant#metadata`, keyed by the DSL's `key:`, not Shopify's namespace/key —
nil when the fragment wasn't requested at all (the common, unconfigured
case), skipping any entry with no value set on that product. Value parsing
(handoff step 4) landed the "reasonable first cut" named in the handoff:
`json`/`dimension`/`measurement`/`list.*` get `JSON.parse`'d, everything else
(plain text, numbers, dates, refs) passes through as Shopify sent it.

Confirmed end to end with an adapter-level spec that calls
`Shopify.configure` *after* the gem's already required (matching a real
consumer's `config/initializers` timing, per handoff step 3's own worry) and
asserts the sent GraphQL body contains the configured identifier — not just
that a hand-built fixture maps correctly.

---

## 22. Roadmap review: what 1.0 still needs (added 2026-08-27)

`0.3.0` shipped (root `CHANGELOG.md`), and §8's original six roadmap steps
are all done, so this section is the re-plan: a proposed next-step list
checked against the code rather than against this log's own claims. Two of
the four items on it were already built and misstated; two are real. The
check also turned up two places where §9/§12 document behavior the gem
doesn't have, which matters more than any of the new features — a security
posture that's only true in the design log is worse than one that's
honestly absent.

**§12 has drifted from the code.** §12 says the gem "stamps a correlation
id per MCP session and includes it on every event." It does not — there is
no `correlation` anywhere in any `.rb` file, and `Observability`
(`portage-ucp/lib/portage/ucp/observability.rb`, 31 lines) is referenced by
exactly one non-spec file (`mcp/server.rb`). §12 also claims redaction of
"any `Money`-adjacent PII"; `REDACTED_KEYS` is three keys
(`payment_token`/`oauth_token`/`authorization`) and nothing handles PII.
Both need resolving in the same pass — either build them or narrow §12 —
and the correlation id in particular is a prerequisite for anything that
wants to group events into "one buy attempt" (see the console below), not a
nicety.

**`Checkout#links` is required by the schema and populated by nobody.**
`Link` (`value_objects.rb`) is defined against
`schemas/shopping/types/link.json` and has zero `Link.new` call sites in the
repo; `Mapper` returns `links: []`. Meanwhile Shopify's own query already
fetches `checkoutUrl` (`queries.rb`), *including* on the
`SubmitFailed { checkoutUrl errors { message } }` branch — which is exactly
the case where an agent hits a wall (3D-Secure, identity verification,
loyalty redemption) and the human has to finish in a browser. The data is
already in hand and thrown away one line later.

This is the whole of what a "handoff" feature needs, and it deliberately is
not a new `Portage::Ucp::Handoff` middleware or a `#to_handoff_url` that
mints a temporary signed URL of the gem's own. §9's never-generates-or-
stores-keys-implicitly rule applies: a gem that wraps a platform session
token in a URL it signs itself has become a credential issuer, with key
management, expiry, and revocation to own. Pass the platform's own URL
through as a `Link` instead. One unresolved detail: link.json's well-known
`type` values are `privacy_policy`/`terms_of_service`/`refund_policy`/
`shipping_policy`/`faq` — there is no "resume this checkout" type. The
schema permits unknown values (consumers "SHOULD handle unknown values
gracefully"), so this means picking a type string, documenting it, and
raising it with UCP rather than assuming a spec-blessed one exists.

**Idempotency exists; the gap is that it's in-process.**
`Support::Idempotency` already dedups per key under a per-key mutex, is
mixed into every adapter, and every mutating `Adapter` method already takes
`idempotency_key:` (§9a, §13's dedup spec). So "an agent retry could
double-charge" is not the current state for a single-process server. What
*is* true is the module's own top-of-file caveat: in-process only, so a
multi-worker deploy doesn't dedup across workers. The fix is to extract a
configurable `idempotency_provider` on `Configuration`, shaped like
`rate_limiter` — an interface plus today's in-memory implementation as the
default, and no bundled Redis, since §9 is explicit that the gem makes no
storage assumption. Worth doing before a scheduler (below) rather than
after: a scheduled purchase runs in a *different process* from the one that
scheduled it, which is precisely where the in-process table is worth
nothing.

**Inbound request signature verification is the one genuine security
hole.** Three signing/verification stories exist and none of them is this
one: `Manifest` signs the outbound `/.well-known/ucp` payload with a
consumer-provided `signer` and a current+next `signing_keys` set;
`Rack::WebhookEndpoint` verifies inbound backend webhooks by HMAC,
verify-first-parse-second; and `Authenticator` authenticates the *caller*
of a `tools/call`. What no code covers is verifying that an inbound agent
request carries cryptographic proof of user consent — the AP2/UCP
authorization story. `Authenticator` returning a truthy auth context proves
who is calling, not that a human agreed to the purchase, and no
`Authenticator` implementation can be made to prove the latter without
parsing signature headers this gem doesn't model.

So: a `Portage::Ucp::Security::Signature` class plus generic Rack
middleware that intercepts, verifies, and parses UCP request signature
headers. Two hard constraints, both already established elsewhere in the
gem and not to be re-litigated: verify before parsing the body (match
`WebhookEndpoint`'s posture exactly — an unverified body is untrusted
input, and parsing it first is the bug that posture exists to prevent), and
reuse the current+next key-set shape `Manifest` already defines rather than
introducing a second, differently-shaped key config on `Configuration`.
Unresearched, and to be pinned before writing code: which signature scheme
and header names UCP actually specifies today, and whether the vendored
`schemas/2026-04-08/` snapshot documents them at all — everything above is
the shape of the hole, not a claim about the wire format that fills it.

**Adapter growth is a confidence problem, not a count problem.** Seven
adapter gems exist (Shopify, Wix, WooCommerce, BigCommerce, Magento, Etsy,
Instagram), all researched in §14 — "broaden beyond Shopify and Wix" is
already done. The real state is §17's leftover: only Shopify has a live
test store, and the other six run the conformance kit against webmock stubs
with the passes-for-the-wrong-reason risk §17 flagged and resolved for
Shopify alone. When Shopify got a real store, the kit immediately caught
four real bugs plus a fifth structural gap (the `Product` vs
`ProductVariant` GID split). Assume the other six are hiding comparable
bugs. The ecosystem work worth doing is sandbox credentials for the six
already written, not an eighth adapter — adding one grows the surface that
*looks* tested without growing what is.

### New scope, not covered by §16

§16 catalogued post-purchase and shopper-agent gaps per order. Four asks
sit outside it, and two of them §16 has effectively already decided:

- **Buyer-side purchase journal** — genuinely new. Nothing records that a
  purchase happened: `Buy` (`portage-cli/lib/portage/cli/buy.rb`) builds a
  report hash and prints it, `complete_checkout` has no journal hook, and
  `dev.ucp.shopping.order` has `get_order` but no list/enumerate action, so
  a buyer can only re-fetch order ids it already kept. Wants an append-only
  record written at the `complete_checkout` boundary (not in the CLI's print
  path) carrying store origin, `source` (`native_ucp` vs
  `adapter:<platform>`), product id, quantity, amount in **minor units plus
  currency** via `Support::Amounts` (never a float), order id, idempotency
  key, timestamp.
- **An admin/console panel** — also new, and blocked on the §12 drift
  above rather than on any UI work. Today's events are
  `logger.info(JSON)`, fire-and-forget, with no sink interface, no event
  store, and no correlation id, so a panel built now would be a log
  scraper. Two security constraints, stated here so they aren't discovered
  later: every field rendered must go through `Observability.redact` (a
  panel is a new place for `payment_token`/`oauth_token`/`Authorization` to
  escape, including into a browser's devtools payload), and the panel needs
  its own session auth — `Authenticator` guards MCP calls, not a web UI,
  and the process holding the panel also holds live platform admin
  credentials in its env. Localhost-bound by default; remote exposure an
  explicit opt-in.
- **Scheduled purchases** — the blocker is already named in §16's
  saved-payment-method entry, and its answer already decided there:
  `payment_token` is single-use and `PaymentTokenGuard` rejects anything
  PAN-shaped, so there is no way to stash a token and spend it later. An
  unattended purchase needs an opaque PSP-issued *reference* exchanged for
  a fresh single-use token at each `complete_checkout`, hung off a linked
  identity — i.e. the `dev.ucp.shopping.payment_method` family, which §16
  also says must ship together with saved addresses and with
  `delete_shopper_data`. Scheduling is therefore not a small feature; it is
  downstream of that whole persistence-and-erasure step. The scheduler
  itself then needs the cross-process `idempotency_provider` above, plus a
  decided policy for price/stock drift between schedule time and run time
  (max-price guard, `OutOfStockError` handling, and an explicit
  skip/notify/proceed rule). No daemon or runner exists anywhere in the
  repo today — every gem is a library plus a stdio exe.
- **Switching between suppliers** — §16 already ruled on this under "is
  this the best price available": not an `Adapter` concern at all, but
  §15's `portage find` multi-store ranking pointed at an item the shopper
  already has, as a "find this same item elsewhere" mode. What that mode
  still needs, and what neither §15 nor §16 resolved: an offer-identity key
  (nothing today can say two products from two stores are the same thing),
  and a policy for comparison cost, since landed price including shipping
  and tax is only known after `create_checkout` — comparing N suppliers
  properly means N speculative checkouts, i.e. rate-limit pressure and
  abandoned carts visible to real merchants. A catalog-price-only ranking
  that only checks out the top two is the obvious compromise, unvalidated.

**Persistence is the common dependency.** Three of those four need durable
state and the repo has none: the only thing written to disk anywhere is
`portage-cli`'s `~/.portage/` pair (`ProbeCache`'s `discovery-cache.json`
and the hand-curated `stores.yml`), both ad-hoc JSON/YAML, and
`Support::Idempotency`/`Support::CheckoutState` are both in-process hashes.
One injectable store abstraction, consumer-swappable in the
`rate_limiter`/`authenticator` mold, decided once — otherwise the journal,
the console, and the scheduler each grow their own incompatible one. None
of it belongs in core `portage-ucp`, which stays a dependency-light
adapter-agnostic library (§2): a console shipping Rack and a database
inside core would break that, so these want their own gems.

### Handoff — the order to build in (do this next)

1. **Populate `Checkout#links`** from each platform's native checkout URL,
   starting with Shopify's already-fetched `checkoutUrl` (both the success
   and `SubmitFailed` branches — the failure branch is the handoff case
   that matters). Decide and document the `type` string first per the
   link.json note above. Smallest commit on this list and unblocked by
   everything else.
2. **Extract `idempotency_provider`** onto `Configuration` with today's
   in-memory `Support::Idempotency` as the default implementation. No new
   runtime dependency. Spec that two providers are interchangeable under
   §13's existing same-key-twice test.
3. **Reconcile §12 with the code**: add the per-session correlation id and
   an event-sink interface on `Observability` (so a consumer can receive
   events rather than only log them), or narrow §12's claims to what
   exists. Do not leave the log claiming an unbuilt security-adjacent
   behavior either way. Same pass: decide what "`Money`-adjacent PII"
   redaction actually means and either implement or drop it.
4. **Research, then build, `Portage::Ucp::Security::Signature`**: pin
   UCP's actual signature scheme and header names against the vendored
   schemas (or the live spec, dated in this log per §1's convention) before
   writing code. Verify-before-parse; reuse `Manifest`'s current+next key
   set. This is the 1.0 blocker of the four.
5. **Sandbox credentials for the six webmock-only adapters**, one at a
   time, running the §17 kit against each. Expect bugs of the same class
   Shopify's real store surfaced. Prefer this over an eighth adapter.
6. **The storage abstraction**, then the purchase journal on top of it.
   Journal first, console second — the console reads the store, never the
   logs.
7. **`dev.ucp.shopping.payment_method` + saved addresses +
   `delete_shopper_data` as one step** (§16's own instruction: shipping
   persistence without a deletion path is the mistake to avoid), and only
   then a scheduler. Anything that automates spending money without that
   step in place is either storing a credential it shouldn't or reusing a
   single-use token §9 forbids.
8. **The find-it-elsewhere mode** last, since it needs an offer-identity
   decision that nothing else on this list depends on.

---

## 23. Handoff — reconciling §12 with the code (added 2026-08-27)

§22 step 3, worked up against the code before touching it. The drift is
wider than "the correlation id is missing," the obvious fix for the
correlation id is wrong, and the audit turned up an ordering bug in
`Mcp::Server.call_tool` that matters more than either.

**Only one of §12's three event types exists.** §12 promises "tool called,
capability negotiated, checkout state transition." The single
`Observability.log` call site in the whole gem is `tool_called` in
`Mcp::Server.call_tool`. `CapabilityNegotiator` (§10) never touches
`Observability`; checkout transitions happen in
`Support::CheckoutState#record_checkout_status`, which is adapter-side
bookkeeping with no logger in reach. Emitting the other two means giving
`Dispatcher` (which today takes only `adapter:`/`registry:`) and the
`CheckoutState` mixin a logger and a correlation id — i.e. the missing
events are a plumbing change through the whole call path, not two more log
lines next to the first.

**Arguments are logged before authorization runs.** In `call_tool`, the
`tool_called` event — including `arguments: kwargs` — is emitted *above*
the `authorize`/`rate_limit` pair, so a caller that fails authentication
and a caller that passes both write to the log identically. Any unauthorized
peer that can reach the endpoint can therefore put attacker-chosen content
into the operator's logs (and, once §22's console exists, onto an operator's
screen) at whatever volume the rate limiter would otherwise have refused,
since the limiter runs after the write too. Fix by emitting a minimal
pre-auth event (capability, action, correlation id — no arguments) and
logging the full argument hash only after `authorize` and `rate_limit` have
both passed. This is the item to do first in this section: it needs no
design decisions, and every event-fan-out feature below makes it worse.

**The obvious correlation-id fix is wrong.** `Mcp::Server::Context` is
built once inside `Server.build`, which is once per process, not once per
session. `mcp` 0.25.0's Streamable HTTP transport is explicitly stateful and
multi-session (`max_sessions`, `session_idle_timeout`,
`session_request_validator`), so one `MCP::Server` object serves many
sessions; memoizing an id onto `Context` would stamp every session in the
process with the same value. That is worse than having none — it reads like
a session trace and isn't. Under stdio the same code would look correct,
which is how it would survive review.

**Take the id from `_meta`, don't invent one.** `mcp` 0.25.0 ships
`MCP::TraceContext`: the MCP spec reserves the un-prefixed `_meta` keys
`traceparent`/`tracestate`/`baggage` for W3C Trace Context (SEP-414), the
SDK guarantees they pass through incoming request `_meta` untouched, and
handlers read them from `server_context[:_meta]`. So the correlation id
should prefer an inbound `traceparent` and generate one only when absent,
rather than portage defining a competing field — an agent that already
traces its own calls then gets one trace across both sides, which is the
whole point of the id. Note `MCP::ServerContext` has no `session_id`
accessor: it exposes `related_request_id` and forwards `method_missing` to
the consumer-supplied context hash. Per-*request* correlation is therefore
available today; per-*session* is only available if the consumer put
something in that hash or the transport's session id is threaded in
deliberately. Decide which §12 is actually promising — per-request plus
inbound `traceparent` is honest and buildable now, and if per-session stays
the goal it needs a documented consumer duty rather than a claim the gem
can't keep on stdio.

**The event sink needs a reason to exist next to `mcp`'s hooks.** `mcp`
already offers `configuration.around_request`, `instrumentation_callback`
(soft-deprecated), `exception_reporter`, and
`ServerContext#notify_log_message` (MCP's own spec-level logging
notifications). A new `config.event_sink` is only justified because
`Observability` events also fire outside an MCP request —
`Rack::WebhookEndpoint` (§11), and the adapter-side checkout transitions
above — which none of `mcp`'s per-request hooks can see. Say that in the
code comment when adding it, or skip the interface and document "wire
`around_request`" instead. Don't ship both seams without a stated
boundary.

**"`Money`-adjacent PII" isn't a real category — resolve the phrase.**
`REDACTED_KEYS` is `payment_token`/`oauth_token`/`authorization`, redacted
recursively through hashes and arrays (specced). `Money`/`Total` carry
amounts and currency codes, no PII. The PII that actually flows through
these events lives on the identity-linking result (§3) and on fulfillment
destinations — names, addresses, contact details. So either extend
`REDACTED_KEYS` to those keys or delete the phrase from §12; leaving it
vague is what puts an address on a console screen later (§22). Deciding
this before the journal and console land is cheaper than retrofitting
redaction into a store that already holds unredacted rows.

**Steps:**

1. Move the full-argument log below `authorize`/`rate_limit` in
   `Mcp::Server.call_tool`, keeping a minimal pre-auth event. Spec both:
   an unauthenticated call emits no `arguments`, an authorized one does.
2. Decide per-request vs per-session correlation, then implement it reading
   `server_context[:_meta]`'s `traceparent` first and generating a fallback
   id only when absent. Spec the generated-fallback path and the
   pass-through path separately, and spec that two sessions in one process
   don't share an id (the `Context`-memoization trap above).
3. Thread logger + correlation id into `Dispatcher` and the `CheckoutState`
   mixin, then emit `capability_negotiated` and the checkout-transition
   event §12 already promises. If either turns out not to be worth the
   plumbing, remove it from §12 rather than leaving it promised.
4. Resolve the PII phrasing: extend `REDACTED_KEYS` with the identity/
   destination keys, or narrow §12. Either way §12 and
   `Observability::REDACTED_KEYS` must say the same thing when this lands.
5. Add the event sink only with the outside-an-MCP-request justification
   written down, and wire `Rack::WebhookEndpoint` through it — a sink whose
   only producer is the one path `mcp`'s own hooks already cover has no
   reason to exist.
6. Rewrite §12 last, describing what the code does, and note in it that
   §12 was aspirational from §0 until this section — the next person
   reading it should be able to tell which parts of this log are decisions
   and which are shipped behavior.

## 24. Handoff — §23 steps 3–6 (added 2026-08-27)

Steps 1 and 2 are done, on branch `handoff-23-observability-correlation-id`
(off `main`, two commits, not yet merged). Steps 3–6 remain.

**What's landed.** `Mcp::Server.call_tool`
(`portage-ucp/lib/portage/ucp/mcp/server.rb`) now emits a pre-auth
`tool_call_received` event (capability, action, correlation_id — no
arguments) before `authorize`/`rate_limit` run, and the full `tool_called`
event with `arguments` only after both pass. A new
`Server.correlation_id_for(server_context)` reads `server_context[:_meta]`'s
`traceparent` (SEP-414, `MCP::TraceContext`) and falls back to
`SecureRandom.uuid` when absent; both events carry the same
`correlation_id` for one call. This is deliberately per-*request*, not
per-*session* — see §23's "obvious fix is wrong" note on why memoizing an
id onto `Server::Context` (built once per process in `.build`) breaks under
`mcp` 0.25.0's multi-session Streamable HTTP transport. Four new specs in
`portage-ucp/spec/mcp/server_spec.rb` cover: no-arguments-when-unauthorized
(from step 1, already existing before this branch — verify it's still
there), fallback generation, traceparent pass-through, and two requests in
one process never sharing a generated id. Full suite (230 examples) and
rubocop both green on this branch as of the last commit.

**Step 3 is the big one — thread logger + correlation id into `Dispatcher`
and `CheckoutState`.** Right now `Dispatcher.new` takes only
`adapter:`/`registry:` (see `portage-ucp/lib/portage/ucp/dispatcher.rb`),
and `CapabilityNegotiator` (§10) never touches `Observability` at all —
so `capability_negotiated` has no call site to add a log line to yet;
find where negotiation actually happens (search for where
`CapabilityNegotiator` is invoked, not just defined) before assuming
`Dispatcher` is the only collaborator that needs the plumbing.
`Support::CheckoutState#record_checkout_status` is adapter-side and has no
logger in reach today, so this needs to decide: does the logger travel with
the adapter instance (constructor arg, mirroring how `Context` already
threads `authenticator`/`rate_limiter`), or does `Dispatcher` wrap adapter
calls and log around them instead of the adapter logging itself? The
correlation id has a harder problem: `Dispatcher.call` and
`CheckoutState#record_checkout_status` are both already-existing method
signatures called from multiple places — check every call site before
adding a `correlation_id:` parameter, since a required kwarg there is a
breaking change for any code that calls the adapter/dispatcher directly
outside `Mcp::Server`. If step 3 turns out not to be worth the plumbing for
either event, §23 already says to cut it from §12 rather than ship it
half-built — don't force both events in if only one turns out clean to
wire.

**Step 4 — resolve the PII phrasing before the journal/console (§22)
land.** Decide identity-linking result (§3) and fulfillment-destination
keys (name, address, contact fields — check `Support::` value objects for
the actual field names) get added to
`Observability::REDACTED_KEYS`, or narrow what §12 promises about
"Money-adjacent PII" instead. Whichever way, `REDACTED_KEYS` in
`portage-ucp/lib/portage/ucp/observability.rb` and §12's prose must end up
saying the same thing — grep for "PII" and "Money-adjacent" in §12 after
deciding to make sure the wording actually changed, not just the code.

**Step 5 — the event sink, only with the write-up done first.** Don't add
`config.event_sink` without writing the outside-an-MCP-request
justification into the code (a comment next to the config option, not just
this log) — the point of the sink is that `Rack::WebhookEndpoint` (§11)
and the adapter-side checkout transitions from step 3 can't reach any of
`mcp`'s own `around_request`/`instrumentation_callback`/
`notify_log_message` hooks. If step 3 ends up not giving `CheckoutState`
a logger, re-check whether the sink is still justified before building it
— a sink whose only producer is the one path `mcp`'s hooks already cover
has no reason to exist, per §23.

**Step 6 — rewrite §12 last.** Do this only after 3–5 land or are
deliberately cut, and say in §12 itself that it was aspirational from §0
until §23 reconciled it, so the next reader can tell decisions from shipped
behavior.

**Step 5 — done (2026-08-27).** Skipped the interface, per §23's own
escape hatch ("skip the interface and document 'wire `around_request`'
instead"): no `config.event_sink` was added. `Rack::WebhookEndpoint` is a
plain Rack app, never built through `Mcp::Server.build`, so it's the one
genuinely-outside-an-MCP-request case — `mcp`'s hooks structurally can't
see it, not just don't happen to. It now takes a `logger:` kwarg
(defaulting to `Portage::Ucp.configuration.logger`, same pattern as every
other logging collaborator in the gem) and emits `order_webhook_received`
(order id, checkout id) on a verified payload and `order_webhook_rejected`
(reason: `invalid_signature` or `bad_request`) on the two rejection paths
— never the body, before or after the signature check. The
adapter-side-checkout-transitions half of the original justification
didn't hold up: `CheckoutState` (step 3) only gets a logger when called
through `Dispatcher`, which today is only reachable from
`Mcp::Server.call_tool` — inside a request, not outside one — so it isn't
a second producer for the same sink. Four new specs in
`portage-ucp/spec/rack/webhook_endpoint_spec.rb` cover both event types
and the rejection-reason field; full suite (237 examples) and rubocop
clean on the touched files.

**Before starting**, rebase/merge `handoff-23-observability-correlation-id`
onto whatever `main` has moved to, and re-run the full spec suite —
steps 1–2 haven't been reviewed or merged yet.
