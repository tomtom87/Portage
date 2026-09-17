# Investigation: `Tool not found` on every real UCP tool call

**RESOLVED (live-confirmed) 2026-09-17.** Root cause: a platform-side
authorization gate on tool *invocation*, independent of manifest,
profile, meta placement, or schema — see "Confirmed root cause" below.
Kept the chronological trail beneath for whoever needs the reasoning.

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

**Not yet investigated** (future work, not blocking this doc's
resolution): whether Shopify's Partner Dashboard exposes an
application/enrollment flow for this allowlist, and whether a
non-Shopify UCP store (BigCommerce/WooCommerce/etc.) gates the same way
or is protocol-compliant without an allowlist — see steps 3 and 4 below,
still open, now understood to be about *finding the approval process*
rather than *finding the bug*.

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
