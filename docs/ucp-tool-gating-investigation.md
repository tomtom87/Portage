# Investigation: `Tool not found` on every real UCP tool call

Handoff note for whoever picks this up next. Status as of 2026-09-17, on
branch `agent-profile-shopping-fixes`.

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
now looks like a **platform-side gate on tool execution** independent of
merchant config — not a per-store permission, not a profile-content problem.
Working theory: Shopify's 2026-08-25 UCP rollout may open catalog discovery
and manifest data broadly (marketing/spec-compliance reasons) while gating
actual tool *invocation* to an allowlist of approved agent partners
(ChatGPT, Perplexity, etc. — publicly announced integrations), rejecting
unrecognized callers with the same generic "Tool not found" rather than a
more specific authorization error. This is a guess, not confirmed.

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

## Suggested next steps

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
