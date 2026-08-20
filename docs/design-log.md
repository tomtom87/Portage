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

Commerce debugging needs a trail. The gem:
- emits structured log events (tool called, capability negotiated, checkout state
  transition) through a consumer-injected logger (defaults to `Logger.new($stdout)`);
- stamps a correlation id per MCP session and includes it on every event so an agent session
  can be traced end to end;
- **redacts** `payment_token`, `oauth_token`, `Authorization`, and any `Money`-adjacent PII
  from logs by default;
- instruments nothing to a specific APM — exposes the events, lets the consumer wire them.

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

---

## 18. Fulfillment / shipping-option selection (added 2026-08-20)

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

This is contract-and-value-objects only. No adapter implements
`fulfillment_supported?` yet — Shopify's mapping (Storefront cart has no
native "fulfillment group" concept; it would mean synthesizing groups from
`availableShippingRates`/`deliveryGroups` and threading `selected_option_id`
back into `cartSelectedDeliveryOptionsUpdate`) is real work, left for its own
follow-up commit rather than bundled here, matching how discount codes'
contract and Shopify-implementation landed as two separate commits.
