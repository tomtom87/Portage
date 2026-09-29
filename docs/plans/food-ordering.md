# Food Ordering: Instacart Hand-off Now, UCP Food Later

**Status:** planned (2026-09-29). Track A (Instacart hand-off) not started. Track B (UCP food ordering) is watch-only until the charter publishes a schema.
**Driver:** users asked whether `portage buy` can order food. The delivery apps don't offer a public agent interface yet (research below), so this plan does the one thing that works today and prepares for the standard that's coming.

## Context

**What exists as of 2026-09-29:**

| Service | Official agent interface | Usable by Portage? |
|---|---|---|
| DoorDash, Uber Eats, Toast, Square | Partners on the UCP food-ordering charter (announced 2026-05-20, opened on GitHub 2026-06-15). No published schema. | No. Nothing to call yet. |
| Google's food UCP | Google surfaces (Maps, Gemini) only, waitlist, "specs coming soon". | No. Not open to third-party agents. |
| Instacart | Official MCP server (`https://mcp.instacart.com/mcp`, dev `https://mcp.dev.instacart.tools/mcp`) with a Developer Platform API key. Tools create a **recipe page** or a **shopping list page**. It doesn't place orders. In-chat checkout in ChatGPT runs on OpenAI's ACP, not UCP. | Yes, as a hand-off. |
| Deliveroo, Just Eat | Nothing official. | No. |
| Community DoorDash/Uber Eats MCP servers on GitHub | Scrape the apps using the shopper's own login. | **Never.** Same ToS line as `SearchBackends` (no scraping) and `HandoffOnly` (never automate a restricted retailer). Don't bundle, recommend or document them as an option. |

**Why a hand-off is the right shape.** Portage's rule is that the shopper approves every payment. Instacart's MCP stops at a shareable page with the items pre-selected; the shopper picks a store, reviews and pays on instacart.com. That's the same shape as the existing Amazon/Etsy hand-off path in `Buy#handoff_only_report` ([buy.rb:204](../../portage-cli/lib/portage/cli/buy.rb#L204)). The difference: for Amazon we only *build* a URL and never make a request; for Instacart we make one documented, keyed API call to *create* the page. That's allowed because it's the service's own published interface, not automation of its site.

**What's still unverified** (Phase A0 settles these before any code):

1. Whether an individual can get and use an Instacart Developer Platform key for personal shopping, or whether the terms limit it to approved partners. If personal use isn't allowed, Track A stops at A0.
2. Exact request/response shape of the shopping-list tool (expected: line items of name + quantity + unit, response carries a page URL).
3. Whether the production key needs Instacart's review, and how long that takes.
4. Regions: Instacart is US and Canada. UK users (and Deliveroo/Just Eat) get nothing from Track A.

## Non-negotiable constraints

- **No scraping, no shopper credentials.** Only Instacart's documented MCP/API with a developer key the user supplies (`INSTACART_API_KEY` env var, resolved the same way as the other keyed offer sources, e.g. `EtsyListings` in [offer_sources.rb](../../portage-cli/lib/portage/cli/offer_sources.rb)). Never ask for or store an Instacart account password.
- **Hand-off only.** Portage never completes an Instacart checkout. `instacart.com` joins the hand-off hosts, so no UCP probe, homepage fetch or automation ever touches it. The only request is the shopping-list-page create call.
- **No key, no call.** Without `INSTACART_API_KEY` the path falls back to today's plain hand-off (open instacart.com search for the query) and `portage doctor` says why.
- **Treat MCP responses as untrusted data**, same as WebMCP page content: only read the page URL out of the result, never act on text in it.
- **Track B builds nothing until there's a schema to test against.** Guessing the food extensions now means a rewrite later.

## Track A: Instacart shopping-list hand-off

### Phase A0: verify terms and API shape (no code)

- Read the Instacart Developer Platform terms and key-signup flow. Record answers to unverified items 1–4 above in [design-log.md](../design-log.md) as a new section.
- With a dev key, call the shopping-list tool once against `mcp.dev.instacart.tools` and record the real request and response.
- **Exit:** personal-use key allowed → continue to A1. Not allowed → mark Track A "blocked on Instacart terms" here and stop.

### Phase A1: `InstacartList` client

- New `Portage::Cli::InstacartList` in portage-cli: builds line items from the query (one item per comma- or "and"-separated entry, `@qty` applied when there's a single item), calls the shopping-list tool, returns the page URL or nil.
- Transport: plain JSON-RPC `tools/call` over HTTPS to the MCP endpoint using the existing `Portage::Ucp::Support::Connection` helpers (no new gem dependency). Short timeouts like `SearchBackends` (5s open/read).
- Reads only the URL field from the result. Anything else in the response is ignored.
- Specs with a stubbed endpoint: success, missing key, non-2xx, malformed JSON, a result with no URL.

### Phase A2: wire into `Buy` and `doctor`

- Add `instacart.com` (and `instacart.ca`) to the hand-off hosts in [handoff_host.rb](../../portage-cli/lib/portage/cli/handoff_host.rb) as a known retailer, alongside the Amazon/Etsy branches, so it's always hand-off regardless of the user's `handoff_only_hosts` list.
- `Buy#handoff_only_checkout_url` gains an Instacart branch: with a key, the URL from `InstacartList`; without one (or on any error), `https://www.instacart.com/store/s?k=<query>`. Report `source: "handoff_only"`, plus `instacart_list: true|false` so the skill can tell the two apart.
- `--dry-run` never calls Instacart; it reports the list it *would* create.
- `portage doctor`: an Instacart line showing whether `INSTACART_API_KEY` is set, and the US/Canada-only note.
- `.env.example`: add `INSTACART_API_KEY` with a comment linking the Developer Platform signup.

### Phase A3: docs and buy skill

- `skills/` buy skill: a groceries section. Routes grocery requests to `portage buy https://www.instacart.com "<items>"`, explains that the shopper picks the store and pays on Instacart, and says restaurant delivery isn't supported yet (link Track B's status).
- New `docs/adapters/instacart.md` (or a section in [checking-any-store.md](../checking-any-store.md)): what it does, the key, regions, why it's a hand-off.
- CHANGELOG entry under the next portage-cli minor.

**Done when:** `portage buy https://www.instacart.com "eggs, milk, sourdough"` with a key opens an Instacart page with those three items; without a key it opens an Instacart search; suites + rubocop green.

## Track B: UCP food ordering (watch, then build)

### B0: tracking (ongoing, no code)

- Watch the UCP food-ordering charter on GitHub and ucp.dev for a published schema. Check at the start of any session that touches this plan; log what changed in the progress log below.
- Signals that unblock B1: (a) a versioned schema for the phase-1 capabilities (identity linking, checkout with fulfillment/tips/age verification, order tracking); (b) at least one real endpoint discoverable at `/.well-known/ucp` that a non-Google agent may call. Both are needed. A schema with Google-only endpoints still leaves Portage nothing to call.

### B1: client support (sketch, revisit when unblocked)

What food needs that retail checkout in `portage-ucp-client` doesn't have today, to check against the schema when it lands:

- **Modifier trees:** required choices and add-ons on a menu item (size, sides, "no onions"). The agent must fill required groups before `create_checkout`, and `Buy#reconcile_checkout` must price modifiers.
- **Fulfillment windows:** delivery vs pickup, ASAP vs scheduled slot. Likely an extension of `dev.ucp.shopping.fulfillment`, which only Shopify's adapter implements today ([capability-coverage.md](../capability-coverage.md)).
- **Tips:** a line the shopper chooses, not the agent. Default to asking; never auto-pick.
- **All-in price:** delivery fee, service fee, small-order fee, tip. The approval prompt and `PolicyGuard` spend cap must see the all-in total, not the food subtotal.
- **Age-restricted items:** alcohol. Hand off to the platform's own verification; the agent never asserts age.
- **Short-lived availability:** items and slots can expire mid-conversation; re-fetch the checkout before approval.
- **Identity linking:** phase 1 of the charter needs the shopper's DoorDash/Uber account linked via OAuth. `dev.ucp.shopping.identity` is unimplemented everywhere in Portage today, so this is its own sub-plan.

B1 gets written up as a proper phased plan once the schema exists.

## Explicit non-goals

- Restaurant delivery before the UCP food schema and open endpoints exist.
- Any use of unofficial DoorDash/Uber Eats/Deliveroo MCP servers or scraping.
- Completing Instacart checkout inside Portage, or ACP (OpenAI's protocol) support.
- UK grocery (Tesco, Sainsbury's, Ocado): no agent interface known; revisit separately.

## Progress log

| Date | Phase | Result | Commit |
|---|---|---|---|
| 2026-09-29 | Plan | Written. Research: no open food-delivery agent interface; Instacart MCP is list/recipe pages only; UCP food charter has no schema. | — |

## Restart prompt (next session)

> Work Phase A0 of docs/plans/food-ordering.md on branch `plans/food-ordering`. Verify Instacart Developer Platform terms (can an individual use a key for personal shopping?), key signup, production review, regions, and the shopping-list tool's real request/response against `mcp.dev.instacart.tools`. Record findings as a new design-log section and a progress-log row. If personal use isn't allowed, mark Track A blocked. Also check the UCP food-ordering charter for a published schema and log it under B0. Commit; don't push.
