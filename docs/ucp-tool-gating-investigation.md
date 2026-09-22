# Investigation: `Tool not found` on every real UCP tool call

**CORRECTED 2026-09-22. The 2026-09-17 conclusion below was wrong.**

There is no allowlist. The agent profile declared capability identifiers
that don't exist in the registry a UCP server resolves an agent's tool
set from, so the server resolved zero catalog tools and reported the
miss as `Tool not found`. Fixed in
`Portage::Cli::Generate::AgentProfile::CAPABILITY_IDS`.

Catalog is registered per action — `dev.ucp.shopping.catalog.search`,
`dev.ucp.shopping.catalog.lookup` — not as one coarse
`dev.ucp.shopping.catalog`. The profile declared the coarse name,
because it reused `Portage::Ucp::Capabilities::CATALOG.name`, which is
right for *our own server's* manifest (one Capability object there owns
all three catalog actions) and wrong for an agent profile. Versions were
`"1"` rather than spec revisions, and `services` was `{}`.

Proven live 2026-09-22, anonymously — no token, no signatures, no
approval — three profiles against the same endpoint on the same
connection:

```
POST https://catalog.shopify.com/api/ucp/mcp   tools/call search_catalog
  profile declaring dev.ucp.shopping.catalog.search + .catalog.lookup  -> 200, 10 products
  profile declaring dev.ucp.shopping.catalog (coarse, what we sent)    -> Tool not found: search_catalog
  a third-party profile also declaring the coarse name                 -> Tool not found: search_catalog
  no profile at all                                                    -> invalid_profile_url
  profile URL that resolves to nothing                                 -> profile_unreachable
```

Then end to end against a store this project does not own
(`www.billabong.com` -> `billabong-us-o5.myshopify.com/api/ucp/mcp`):
`tools/list` returns all thirteen tools to an anonymous caller,
`search_catalog` returns 290KB of live products with variant GIDs,
prices and availability, and `create_cart` returns a real cart with a
`continue_url`. And against our own dev store
(`ucp-test-bc2vif1p.myshopify.com`), the exact call this document was
opened about: `search_catalog` -> 10 products; `create_cart` -> a cart
holding the line item at `94995 USD`; `create_checkout` -> a checkout
with `status: "incomplete"`, its totals, its outstanding requirements
(contact method, delivery address) and a `continue_url`. Stopped there
deliberately — `complete_checkout` was never called and nothing was
bought.

## Why the 2026-09-17 reasoning went wrong

Worth keeping, because the mistake was subtle and the evidence looked
conclusive.

The load-bearing tell was `get_order` returning an honest `"You are
forbidden to make tools/call requests"` while `search_catalog` returned
`Tool not found` on the same session. That was read as one gate
surfacing inconsistently across capability domains. It is in fact two
different things:

- **`get_order` really is forbidden** at the anonymous tier. Orders
  needs a Dev Dashboard token carrying `read_global_api_orders`. That
  error was accurate and had nothing to do with catalog.
- **`search_catalog` was a registry miss** caused by our own profile.

Reading the first as the explanation for the second turned a client-side
bug into an imagined platform policy. The profile-content test that
seemed to rule the profile out — real profile vs. garbage URL producing
different errors — only ever proved the server *fetches* the profile. It
never varied the one thing that mattered: which capability ids the
profile declared. Both profiles tested declared the same wrong ones.

Shopify's [auth and rate limiting](https://shopify.dev/docs/agents/profiles/auth-and-rate-limiting)
documents three tiers, and the anonymous one — "no credentials or
signatures provided" — carries Catalog, Cart and Checkout build/edit
tools. That was available to read throughout and would have contradicted
the allowlist theory.

## What is genuinely gated

`complete_checkout`, and only that. It needs both checkout permission on
the client's token and the merchant having your agent's channel enabled
on their shop, granted case by case with no public application or
waitlist ([Alan_G, 2026-09-02](https://community.shopify.dev/t/how-can-a-token-tier-ucp-client-obtain-permission-to-call-complete-checkout/36590)).
The supported path without it is `continue_url`: the shopper finishes in
the merchant's own checkout. Every cart and checkout response carries
one, so a full browse -> select -> cart -> checkout -> hand-off flow
works today with no Shopify involvement at all.

## Second bug, found underneath the first

Once tool calls worked, `create_cart` returned `line_items: []`, zeroed
totals, and:

```
"code": "merchandise_out_of_stock",
"content": "The product 'The Inventory Not Tracked Snowboard' is already sold out."
```

for a variant `search_catalog` had just returned as
`availability.available == true` on the same store, seconds earlier.

Cause: the UCP `context` object (`address_country`, `address_region`,
`postal_code`, `currency`, `language`) was never sent. A store resolves
which market — and therefore which publication and which inventory — a
call is scoped to from it. Without one, the cart is scoped to no market
and every line silently drops. The spec calls context "provisional
hints ... unsupported hints may be ignored without error", which reads
as decorative and isn't.

Same `create_cart`, context added, nothing else changed:

```
"line_items": [ { "quantity": 1, ... } ],
"totals": [ { "type": "total", "amount": 94995, "display_text": "Total" } ]
```

Fixed by threading a `context:` through `Session` and
`Transports::Http` (`#with_context`), built from `PORTAGE_SHIP_*` /
`PORTAGE_CURRENCY` / `PORTAGE_LANGUAGE` by
`Portage::Cli::BuyerContext`. Note this failed *open*, in the worst way:
a plausible-looking "sold out" answer rather than an error, which would
have read as the merchant's stock problem rather than our bug.

One more live-only discrepancy: `checkout.cart_id`'s schema says a
`cart_id` alone is enough to convert a cart into a checkout ("the
business uses cart contents and ignores overlapping fields"). The server
rejects that with `Invalid arguments: object at '/checkout' is missing
required properties: line_items`, so `Transports::Http` sends both.

---

Everything below is the original 2026-09-17 investigation, kept verbatim
for the reasoning trail. **Its conclusions about an allowlist are
superseded by the above.**

## The problem

Once a UCP HTTP call to a real Shopify store carries a fetchable, correctly
hosted `meta.ucp-agent.profile`, every tool call — `search_catalog`,
`lookup_catalog`, `get_product`, `create_cart`, all of them, regardless of
capability domain — comes back:

```
MCP::Client::ServerError: Invalid params
code: -32602
data: "Tool not found: <name>"
```

`tools/list` on the same connection returns all of these tools seconds
earlier. So it isn't that the tool doesn't exist — something about the
calling agent isn't authorized to invoke it.

## What's been ruled out

1. **Manifest/discovery** — works. `GET <store>/.well-known/ucp` resolves,
   `services`/`capabilities` parse, native MCP endpoint connects, `initialize`
   handshake succeeds, `tools/list` returns the full tool set.
2. **Agent-profile hosting** — was broken (raw.githubusercontent.com serves
   the checked-in profile as `text/plain`, real UCP servers reject that as
   `profile_malformed`, surfaced as an opaque empty-body 422). Fixed: this
   branch's `.env.example` now points `PORTAGE_AGENT_PROFILE` at
   `cdn.jsdelivr.net/gh/tomtom87/Portage@<ref>/portage-cli/agent-profile/agent-profile.json`
   (confirmed `application/json`, no redirect, long `Cache-Control`). Confirmed
   this resolves cleanly — no more `profile_malformed`/422.
3. **Empty `capabilities` in the agent-profile document** — was empty
   (`{}`), which read like "this agent declares no capabilities, so nothing
   authorizes." Fixed: `Portage::Cli::Generate::AgentProfile` now populates
   it with the same `{name: [{version:}]}` shape
   `Portage::Ucp::Manifest#capability_hash` uses for a business's own
   manifest, reusing `Portage::Ucp::Capabilities::{CATALOG,CART,CHECKOUT,ORDER}`.
   **Retested live — did not fix it.** Identical `Tool not found` with the
   populated profile.
4. **"Maybe it's just billabong.com being a stranger's store"** — ruled out.
   Same exact failure against `ucp-test-bc2vif1p.myshopify.com`, a Shopify
   Plus App Development store this project owns outright, with its own admin
   credentials in `.env` (`SHOPIFY_ADMIN_ACCESS_TOKEN` etc. — real access,
   `portage` app installed with `read_products`/`read_checkouts`/
   `write_checkouts`/etc. scopes). Owning the store didn't change the
   result.

Since it fails identically on a store we administer and one we don't, this
looked like a platform-side gate independent of merchant config — and
that's exactly what it turned out to be, confirmed live below. A more
specific "wrong envelope" lead was investigated first, in good faith
(cheaper to falsify), and ruled out; kept here for the trail.

## Dead end investigated and ruled out (2026-09-17): `meta` envelope placement

`Transports::Http#call_tool` (`portage-ucp-client/lib/portage/ucp/client/transports/http.rb:48-72`)
never sends the MCP protocol's spec `_meta` field. It folds
`meta.ucp-agent.profile` into `arguments["meta"]["ucp-agent"]["profile"]`
instead — a sibling property of `catalog:`/`cart:`/`checkout:` inside the
tool's own arguments object — and never passes the `mcp` gem's own
`meta:` kwarg (which *would* produce spec-correct `params._meta`) through
to `@client.call_tool`. This is deliberate, per the comment at
http.rb:41-47 and the commit that introduced it (`fe0317b`, "Build the
real nested wire shape for HTTP tool calls"), which asserts this was
"confirmed live against Shopify's 2026-08-25 rollout."

That claim doesn't hold up under scrutiny:

- `fe0317b` fixed a **422** (structurally malformed request — flat
  arguments instead of nested under a capability key). It did *not*
  isolate the meta-placement question from the arguments-nesting
  question; both changed in the same commit.
- The bug this doc tracks is a **different, later-stage error**
  (`-32602 Tool not found`, not 422), which showed up only *after*
  fe0317b's nesting fix, once the request was well-formed enough to
  clear whatever validation was producing the 422.
- "Tool not found" is a strange error for an arguments-shape problem —
  it targets the JSON-RPC method dispatch (routing by `params.name`)
  itself, not `params.arguments` validation. That's more consistent
  with the server treating the *session* as anonymous/unrecognized once
  a profile is present in a shape it doesn't expect, and falling back to
  an empty or different tool registry for that call — which would also
  explain why the failure is identical across every capability domain
  (catalog/cart/checkout), not just checkout-adjacent ones.
- The only test coverage for this (`http_spec.rb:31-96`) mocks
  `MCP::Client#call_tool` and asserts against the *intended* wire shape.
  It proves the code does what the comment says, not that Shopify's
  server accepts it. No cassette/fixture of an actual real-store
  response exists anywhere in this repo.
- `MCP::Client#call_tool` (mcp gem, `mcp/client.rb:342-355`) already
  supports sending real `params._meta` via its own `meta:` kwarg —
  `Http#call_tool` just never passes it (`http.rb:52` only passes
  `name:`/`arguments:`). `Stdio` and `Loopback` transports *do* use real
  `_meta`; only the `Http` transport (the one path that talks to actual
  Shopify) diverges.

**Live-tested and ruled out** (once `.env` was in place — thanks to
whoever restored it) against `ucp-test-bc2vif1p.myshopify.com`, straight
through `MCP::Client#call_tool`, bypassing this gem's own transport
entirely to isolate the wire shape:

- Real spec `params._meta["ucp-agent"]["profile"]`, sent via the `mcp`
  gem's own `meta:` kwarg (alongside the existing `arguments["meta"]`
  shape, so nothing existing was removed): **identical** `Tool not
  found: search_catalog`. Adding the spec envelope changed nothing.
- Hand-built minimal request matching `search_catalog`'s advertised
  `input_schema` *exactly* (confirmed by pulling the live schema via
  `client.tools.find { |t| t.name == "search_catalog" }.input_schema` —
  required `meta.ucp-agent.profile` and `catalog.query`, nothing more):
  still `Tool not found: search_catalog`. The request is provably
  schema-valid; this isn't an arguments-shape bug.

So `meta` placement and arguments shape are both cleared. The `_meta`
lead in this doc's history was a red herring — worth the ~30 minutes it
took to rule out, since it was cheap and well-reasoned, but it wasn't
the answer.

## Confirmed root cause

Calling **`get_order`** with the exact same session/profile returns a
completely different, honest error:

```
MCP::Client::RequestHandlerError: You are forbidden to make tools/call requests
```

— not "Tool not found." And it's identical whether `meta.ucp-agent.profile`
points at our real, valid, fetchable agent-profile document or at
`https://example.com/definitely-not-a-real-profile.json` (a URL that
resolves to nothing UCP-shaped). Profile content is provably irrelevant
to this rejection.

`search_catalog`, `get_product`, `lookup_catalog`, `get_cart`,
`create_cart`, and `get_checkout` all uniformly return `Tool not found:
<name>` with a real profile — but swap in the garbage profile URL and
`search_catalog` instead returns `The tools/call request is
unprocessable` (a different error again). That difference proves the
server *does* fetch and validate the profile before deciding what to do
next; a real, valid profile clears that check and the request proceeds
further, only to have its tool filtered out of whatever per-agent tool
registry this session resolves to.

**Conclusion**: this is exactly the platform-side gate the original
working theory guessed at — Shopify's UCP rollout authorizes tool
*invocation* per-agent independent of profile validity or request
correctness, most likely against an allowlist of approved agent
partners. It's just surfaced inconsistently across tool domains: Orders
returns an honest, explicit "forbidden"; Catalog/Cart/Checkout instead
silently drop the tool from the registry and return a generic "not
found" — cheaper to implement (a lookup miss) but a confusing error to
debug from the outside, since `tools/list` still advertises those same
tools moments earlier with no per-agent scoping visible in the
manifest/schema.

**What this means for Portage**: nothing in this client is broken.
There is no code fix available to Portage — a store this project doesn't
control gates who it lets call tools, and neither the manifest nor the
agent-profile document exposes any signal about how to apply for or
check that approval. If Shopify publishes a partner-registration or
allowlist-application process, that's the only path to a working
integration against real Shopify UCP stores; short of that, this client
is correct and complete, and the failure is entirely external.

**Not yet investigated**: whether a non-Shopify UCP store
(BigCommerce/WooCommerce/etc.) gates the same way or is
protocol-compliant without an allowlist — see step 4 below.

## Can Portage sidestep the gate by running its own UCP server for a merchant? No.

Investigated 2026-09-17: whether `portage-ucp-shopify`'s existing UCP
server (currently serving our own store via the Loopback transport,
backed by that store's Admin API creds) could become an installable
Shopify app that runs an HTTP UCP server against a **third-party**
merchant's Admin API after OAuth install, with Shopify routing agent
traffic to it instead of its own native endpoint.

**Answer: no such mechanism exists.** Shopify's `/.well-known/ucp` and
native MCP endpoint are platform-served, fixed per-shop URLs
(`https://{shop}.myshopify.com/api/ucp/mcp` for UCP catalog tools,
`https://{shop}.myshopify.com/api/mcp` for Storefront MCP) with no
registration surface an installed app can hook into:

- The full app-extensions reference
  (shopify.dev/docs/apps/build/app-extensions/list-of-app-extensions,
  24 extension types: Admin actions/blocks, Checkout UI, Functions, POS
  UI, Theme app extensions, Flow triggers/actions, Web pixels, Payments,
  etc.) has nothing for agentic commerce, UCP, MCP, or `/.well-known`
  registration.
- No webhook topic or Partner/Developer Dashboard toggle for this
  either. Shopify's Spring '26 Developer Dashboard update
  (shopify.com/news/spring-26-edition-dev) covers registering *your
  agent's* UCP-client profile — the opposite direction, not a way for a
  merchant's app to register/override their store's own UCP server.
- One exception, doesn't apply here: Hydrogen (Shopify's headless
  storefront framework) has a `proxyStandardRoutes` setting letting a
  merchant who built their own Hydrogen storefront front `/api/mcp`
  themselves. Only works when the storefront *is* a custom Hydrogen app
  the merchant built — not a hook a third-party OAuth-installed app can
  use against an arbitrary existing (non-Hydrogen) store.

**So**: building this would produce a working UCP server, but nothing
makes Shopify route agent traffic to it instead of its own hosted
endpoint at that merchant's domain. Dead end — don't build it.

**Allowlist/approval process — found, and it's worse than hoped.** No
public self-serve application or waitlist exists. Shopify staff
(`Alan_G`) confirmed on the Shopify Dev community forum
(community.shopify.dev/t/how-can-a-token-tier-ucp-client-obtain-permission-to-call-complete-checkout/36590):
> "Direct `complete_checkout` is granted on a case by case basis and
> there isn't a public application or waitlist for self-serve platforms
> at the moment."

Token-tier Dev Dashboard credentials don't include checkout-completion
permission and "isn't something you can add from the scope picker."
Shopify's suggested workaround is a `continue_url` redirect to the
merchant's own storefront checkout (or Checkout Kit) — not a real
programmatic tool-call path. This matches this doc's own live finding
(`get_order` → explicit "You are forbidden to make tools/call
requests").

One unverified claim surfaced during search (a "Universal Commerce
Agent" App Store app that supposedly auto-serves `/.well-known/ucp` on
install) could not be confirmed to exist — likely a search-summarizer
hallucination. Real, verifiable App Store apps found (AgentCart,
AgentReady: UCP & Catalog) only optimize product/catalog data for
Shopify's *existing* platform-served UCP surface; they don't replace or
front the endpoint.

**Conclusion for the roadmap fork**: no client-side or app-side
workaround exists. Only path to real tool-call authority against
Shopify UCP stores is direct outreach to Shopify for case-by-case
approval — there is no documented partner-approval workflow to point at
yet. Building a self-hosted UCP server app is a dead end and should not
be attempted.

## Workaround found and proven live (2026-09-17)

The gate applies to Shopify's **UCP** MCP endpoint (`/api/ucp/mcp`). Two
other surfaces on the same store are *not* gated. Both tested live
against `ucp-test-bc2vif1p.myshopify.com`.

### 1. Storefront MCP (`/api/mcp`) — ungated, but dying

Separate endpoint from `/api/ucp/mcp`, never tested before this pass.
`initialize`, `tools/list` and `tools/call` all succeed with **no auth,
no agent profile, no allowlist**:

```
POST https://<shop>/api/mcp   {"method":"tools/call","params":{"name":"search_shop_policies_and_faqs",...}}
=> {"result":{"content":[{"text":"[{\"question\":\"Do you allow customers to request...\"}]"}],"isError":false}}
```

Real data back. No `Tool not found`, no "forbidden". This proves the
gate is specific to the UCP endpoint, not a store-wide agent policy.

**But it's unusable as a foundation:**

- It carries no catalog tools. Per
  shopify.dev/docs/apps/build/storefront-mcp/servers/storefront the
  tools here are `get_cart`, `update_cart`,
  `search_shop_policies_and_faqs`. Catalog (`search_catalog`,
  `lookup_catalog`, `get_product`) lives only on the gated
  `/api/ucp/mcp`.
- It is past its announced sunset. Response headers carry
  `deprecation: @1782259200`, `sunset: Mon, 31 Aug 2026 00:00:00 GMT`,
  `link: <https://shopify.dev/docs/agents>; rel="successor-version"`,
  and calling `get_cart` returns in-band:
  > "DEPRECATION NOTICE: This tool is served by the Storefront MCP
  > server at /api/mcp and will no longer be accessible after August 31,
  > 2026. Migrate to the UCP-conforming tools at /api/ucp/mcp."

  That date passed 17 days before this test. It still answers, but
  Shopify is explicitly routing everyone onto the gated endpoint.

So: the ungated MCP surface lacks catalog and is scheduled to die; the
surface with catalog is gated. Don't build on `/api/mcp`.

### 2. Storefront API — ungated, durable, and enough (recommended)

The whole shopping flow works over the plain **Storefront GraphQL API**
with a public storefront access token — no MCP, no agent profile, no
approval. Proven end to end:

- **Catalog**: `{ products(first:5){ nodes{ title availableForSale } } }`
  returns live products. (Note: Admin API shows `onlineStoreUrl: null`
  on this store — products are unpublished to Online Store — and the
  Storefront API serves them anyway.)
- **Cart**: `cartCreate(input:{lines:[{merchandiseId:..., quantity:1}]})`
  returns a real cart with `id`, `totalQuantity` and
  `cost.totalAmount` (`949.95 USD`), `userErrors: []`.
- **Checkout**: that same cart carries a working `checkoutUrl`
  (`https://<shop>/cart/c/<token>?key=...`) — hand it to the user and
  Shopify's own checkout completes the purchase.

This is exactly the `continue_url` handoff Shopify staff recommended in
the `complete_checkout` thread, except it needs nothing from Shopify:
the Storefront API is stable, public, documented and not deprecated,
and `complete_checkout` approval becomes irrelevant because the shopper
finishes in Shopify's own checkout.

### Bug found while validating the ungated path

`portage-ucp-shopify`'s Adapter already never touched Shopify's native MCP
endpoint — it talks straight to Admin + Storefront GraphQL, and
`Mapper#checkout_links` already hands back the cart's `checkoutUrl` as a
`resume-checkout` Link. So the "workaround" needed no new transport. But
running the live buyer-journey spec against it surfaced a real defect:

Catalog is read through the **Admin** API, while the cart those results
get added to is written through the **Storefront** API. Admin sees
`DRAFT`/`ARCHIVED` and unpublished products; the Storefront Cart does
not. `random_purchase_spec` picked "The Draft Snowboard" out of a catalog
search and `cartCreate` rejected it:

```
Portage::Ucp::Shopify::UserError:
  cartCreate userErrors: The merchandise with id
  gid://shopify/ProductVariant/45662494851119 does not exist.
```

An agent could search up a product and then be unable to buy it.

**Fixed by moving all three catalog reads (`search_catalog`, `get_product`,
`lookup_catalog`) onto the Storefront API**, so the catalog and the cart
now read from the same place and the mismatch is impossible by
construction rather than filtered after the fact. Verified live through the
adapter:

```
get_product(draft)    -> nil
get_product(archived) -> nil
get_product(live)     -> The Inventory Not Tracked Snowboard
lookup_catalog(all 3) -> ["The Inventory Not Tracked Snowboard"]
search_catalog        -> 16 products, no Draft/Archived
```

An Admin-side filter (`status:active AND published_status:published`) was
tried first and rejected: it returned only 13 products where Storefront
serves 16, i.e. it hid three genuinely sellable products while still
leaving `get_product`/`lookup_catalog` unscoped, since those take a
caller-supplied GID and have no query to filter. Storefront is the
authority on what's purchasable, so reading from it directly is both more
correct and smaller.

Schema differences this required, all confirmed against the live
Storefront 2026-04 API rather than assumed:

- variant `price`/`compareAtPrice` are `MoneyV2` objects, not Admin's bare
  `Money` scalar — so `Mapper#scalar_price` is gone and `currency` no
  longer has to be threaded down from the parent product.
- `compareAtPriceRange` uses `minVariantPrice`/`maxVariantPrice`, not
  Admin's `minVariantCompareAtPrice`/`maxVariantCompareAtPrice`.
- Storefront always returns `compareAtPriceRange`, **zeroed**, where Admin
  returned `nil` outright. `Mapper#compare_at_price_range` now treats an
  all-zero range as absent, preserving the existing "no strikethrough price
  means the field is absent, not present-and-zero" intent.
- Storefront only returns metafields the merchant has exposed to it, so a
  configured `metadata_field` can come back `null` where Admin would have
  served it. Noted in `Queries.metafields_fragment`.

Bonus: catalog no longer needs an Admin token at all — the verification
above ran with a storefront token only. Orders still require Admin.

### What this means for the roadmap

Portage does not need Shopify's UCP endpoint at all. `portage-ucp-shopify`
can back its UCP server with the Storefront API instead of the gated
native endpoint, and serve catalog + cart + a checkout handoff today.

The one thing still unavailable is *discovery*: Shopify owns
`/.well-known/ucp` on the merchant's domain (see section above — no
override mechanism exists), so agents that discover UCP through the
store domain will keep landing on Shopify's gated endpoint. Agents have
to be pointed at Portage's endpoint directly. That's a distribution
problem, not a technical one.

**Untested**: whether a fully-configured production store exposes more
tools on `/api/mcp` than our dev store did. Probing a third-party store
(billabong.com) was declined as out of scope for this repo, and our dev
store lacks an Online Store channel, so the tool inventory seen here may
not be representative. Doesn't change the conclusion — `/api/mcp` is
past sunset either way.

Citations: shopify.dev/docs/agents, shopify.dev/docs/agents/profiles,
shopify.dev/docs/agents/get-started/profile, shopify.engineering/ucp,
shopify.dev/docs/apps/build/app-extensions,
shopify.dev/docs/apps/build/app-extensions/list-of-app-extensions,
shopify.dev/docs/apps/build/storefront-mcp/servers/storefront,
shopify.com/news/spring-26-edition-dev,
community.shopify.dev/t/how-can-a-token-tier-ucp-client-obtain-permission-to-call-complete-checkout/36590

## Reproduction

```ruby
require "portage/ucp"
require "portage/ucp/client"

meta = { agent_profile: "https://cdn.jsdelivr.net/gh/tomtom87/Portage@agent-profile-shopping-fixes/portage-cli/agent-profile/agent-profile.json" }

# Either store reproduces it:
session = Portage::Ucp::Client.discover("https://ucp-test-bc2vif1p.myshopify.com")
# session = Portage::Ucp::Client.discover("https://www.billabong.com")

session.search_catalog(query: "snowboard", limit: 3, meta: meta)
# => MCP::Client::ServerError: Invalid params ("Tool not found: search_catalog")
```

Run from `portage-cli/` with `bundle exec ruby <script>`.

### How the `_meta`/allowlist question was settled live

For reference, the discriminating call was `get_order` vs `search_catalog`
with the same session, real profile, and (separately) a garbage profile
URL — reaching straight past this gem's transport into `MCP::Client#call_tool`
to rule out any client-side wire-shape bug:

```ruby
require "portage/ucp"
require "portage/ucp/client"

session = Portage::Ucp::Client.discover("https://ucp-test-bc2vif1p.myshopify.com")
client = session.instance_variable_get(:@transport).instance_variable_get(:@client)

real_profile    = "https://cdn.jsdelivr.net/gh/tomtom87/Portage@agent-profile-shopping-fixes/portage-cli/agent-profile/agent-profile.json"
garbage_profile = "https://example.com/definitely-not-a-real-profile.json"

[real_profile, garbage_profile].each do |profile|
  meta = { "ucp-agent" => { "profile" => profile } }
  client.call_tool(name: "get_order", arguments: { "meta" => meta, "id" => "gid://shopify/Order/1" }) rescue $!
  client.call_tool(name: "search_catalog", arguments: { "meta" => meta, "catalog" => { "query" => "snowboard" } }) rescue $!
end
# get_order:      "You are forbidden to make tools/call requests" — identical for both profiles
# search_catalog: "Tool not found" (real profile) vs "The tools/call request is unprocessable" (garbage profile)
```

The `get_order`/`search_catalog` split (see "Confirmed root cause" above)
is what proved this is a platform gate rather than a client-side bug.

## Suggested next steps

Steps 1–2 below (spec docs, embedded transport) are superseded by the
confirmed root cause — the gate isn't a wire-format or transport issue, so
neither would have changed the outcome. Left for reference. Steps 3–4 are
now the live open items: finding the actual allowlist/enrollment path.

1. **Read Shopify's actual UCP/agentic-commerce docs** for any mention of a
   partner allowlist, agent registration process, or pilot/beta gating on
   tool execution — start at `https://ucp.dev` (the spec site the manifest
   itself links to) and Shopify's dev-facing agentic commerce docs. Look
   specifically for whether `meta.ucp-agent.profile` alone is supposed to be
   sufficient identification, or whether there's a separate
   registration/approval step real agents go through.
2. **Try the `2026-04-08` "embedded" transport** instead of the
   `2026-08-25` native MCP transport — the manifest advertises both
   (`services["dev.ucp.shopping"]` has two entries). It's untested whether
   "embedded" behaves differently or requires different call shapes; worth
   ruling in/out.
3. **Check the Shopify Partner Dashboard** for the dev store's `portage` app
   — is there an "Agentic Commerce" / "UCP" toggle, feature flag, or
   developer-preview enrollment that hasn't been requested/enabled? The
   Admin API access scopes we have don't include anything UCP-specific, so
   this may be a dashboard-only setting outside the API.
4. **Find a second, non-Shopify live UCP store** to test against — this
   investigation only ever tested Shopify (billabong.com and our own dev
   store are both Shopify). If a BigCommerce/WooCommerce/independent UCP
   store answers real tool calls the same way, the gate is protocol-wide;
   if it doesn't gate, this is Shopify-specific and worth reporting to
   Shopify or working around differently.
5. If you find the actual gate, come back and correct
   `docs/agent-profile.md`'s "Still open" section and
   `skills/shop-via-ucp.md`'s troubleshooting entry — both currently say
   "unconfirmed, ruled out X and Y" and should be updated with whatever's
   found, same as this doc.
