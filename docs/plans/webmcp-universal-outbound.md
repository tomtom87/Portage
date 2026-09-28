# WebMCP Outbound: Platform Presets and Schema Matching

**Status:** Phase 0 shipped (2026-09-28). Phase 1 next. See [Progress log](#progress-log).
**Driver:** the outbound half of `portage-ucp-webmcp` already calls any page's WebMCP tools, Portage-powered or not. In practice it only works against a store when the caller knows that store's tool names in advance and passes `tool_names:` by hand. The one population with WebMCP tools today, Shopify storefronts, needs `tool_names: { create_cart: "add_to_cart" }`, and nothing in Portage supplies it. This plan makes the outbound path work against a WebMCP page with no per-store setup: a known platform gets a built-in preset, and an unknown one gets a proposed mapping that the user confirms.

## Context

**What "universal" can and can't mean here.** WebMCP reaches only pages that register tools. The polyfill (`WebMcp.polyfill_js`) gives a page with no `modelContext` something to register into; it can't give tools to a page that registers none. Today that's some Shopify storefronts (6 of 8 checked on 2026-09-23 register the same 11 tools; Gymshark and Fashion Nova none) and effectively no WooCommerce, Magento, BigCommerce or custom stores. The platform adapters and native UCP stay the route for everything else. This plan widens what we can do with pages that *do* register tools. It does not replace any adapter.

**Checkout stays a hand-off.** `ToolCatalog` leaves `complete_checkout` out by default, Shopify's tools end in `proceed_to_checkout` (a navigation, not data), and `Buy#webmcp_flow` forces `force_handoff: true` ([buy.rb:254](../../portage-cli/lib/portage/cli/buy.rb#L254)). WebMCP gets as far as a cart plus a checkout URL; the shopper pays in the browser. Nothing here changes that. `token` mode stays a refusal until the prerequisites in [handoff-reconcile.md](handoff-reconcile.md) Phase 4 land.

**Existing bug: the WebMCP path in `Buy` never runs against a real page.** `webmcp_flow` calls `Portage::Ucp::WebMcp.connect(bridge: @webmcp_bridge)` with no `capabilities:`, so the Session's `capabilities` is `nil`. `Session#advertises?` then returns `nil` ([session.rb:37](../../portage-ucp-client/lib/portage/ucp/client/session.rb#L37)), and the guard `return nil unless session.advertises?(CART_CAP) && session.advertises?(CHECKOUT_CAP)` ([buy.rb:250](../../portage-cli/lib/portage/cli/buy.rb#L250)) always falls through to the platform adapter. `buy_spec.rb` doesn't catch this because it stubs `WebMcp.connect` to return an `instance_double` with `advertises?: true` ([buy_spec.rb:1004](../../portage-cli/spec/portage/cli/buy_spec.rb#L1004)). Phase 0 fixes this, since presets are pointless while the flow can't start.

**Where the seams already are.** `Transport` resolves an action as `tool_names[action]`, then `"#{prefix}#{action}"`, then the bare action ([transport.rb](../../portage-ucp-webmcp/lib/portage/ucp/webmcp/transport.rb) `#resolve`), and chooses the argument shape per tool from its `inputSchema` (`wire: :auto`). A preset is just a `tool_names:` hash plus a `wire:` choice, chosen before `connect`. No new transport is needed.

**Trust.** Tool names, descriptions and schemas come from the page, which is untrusted content. A page can name a tool `search_catalog` and have it do something else, or put instructions in its description. That rules out letting page text alone decide which tool a consequential action maps to (see Phase 2).

## Decisions (2026-09-28)

1. **A hand-off-only checkout tool counts as checkout.** A page with a cart plus a tool that sends the shopper to the store's own checkout (Shopify's `proceed_to_checkout`) advertises checkout. `Buy` gets the checkout URL from it and opens it for the shopper through the existing `CheckoutHandoff` auto-open. Built in Phase 1, together with the Shopify preset, because it's Shopify-shaped and needs a live check.
2. **Autofill with the shopper's approval.** Once the shopper approves, the agent may fill the store's checkout page (contact and shipping, from `PORTAGE_SHIP_*`) and step through it, stopping at payment. New Phase 3.
3. **Confirmed mappings are shared, not kept per origin.** They're keyed by the page's tool fingerprint, so one confirmation covers every store running the same tool set. The aim is the widest coverage possible.
4. **Work one phase per session.** Finish a phase, record it in the progress log below, and hand off with the prompt for the next session.

## Phases

### Phase 0: WebMCP sessions derive capabilities from the page's tools ✅

- `WebMcp::Capabilities.for(transport)` ([capabilities.rb](../../portage-ucp-webmcp/lib/portage/ucp/webmcp/capabilities.rb)) maps the actions a page answers (after `tool_names:`/`prefix:` resolution, through the new `Transport#answers?`) to capabilities. A capability counts when the page answers the action that *starts* it: `search_catalog`/`get_product`/`lookup_catalog` → catalog, `create_cart` → cart, `create_checkout` → checkout, `get_order` → order.
- `WebMcp.connect` uses it when the caller passes no `capabilities:`. This reads the page once inside `connect`, so a `BridgeError` can raise from there; `Buy#webmcp_flow` already rescues it.
- Regression: `buy_spec` "runs the WebMCP flow through the real connect against a page's tools". It fails without the fix (`source` is `"none"`) and passes with it.
- The hand-off-only checkout tool is **not** in `STARTING_ACTIONS` yet. If it were added now, a Shopify page would pass `Buy`'s gate and then hit `ToolNotFoundError` on `create_checkout`. It's added in Phase 1 together with the path that uses it.

### Phase 1: platform presets, and the hand-off checkout path

- `WebMcp::Presets` holds one entry per known platform: `tool_names:`, `wire:`, and a **fingerprint**, i.e. the exact set of tool names that platform registers. Shopify is the first and only entry until another platform ships WebMCP.
- `WebMcp::Presets.detect(tools)` picks a preset only on an exact fingerprint match against `bridge.list_tools`. Page text such as the `generator` meta tag or `window.Shopify` is not used, because anything the page can set can be forged, and a fingerprint is what the mapping actually depends on.
- `WebMcp.connect(bridge:, preset: :auto)` is the new default. `:auto` detects; `nil` turns presets off; a symbol (`:shopify`) forces one. An explicit `tool_names:` always wins over a preset, key by key.
- Shopify's odd actions (`update_cart_lines` takes line ids, `proceed_to_checkout` navigates) get small adapter lambdas inside the preset, not new Session methods. Only map what fits Session's contract; leave the rest unmapped and documented.
- **Hand-off checkout (decision 1).** The preset names a `handoff_checkout` tool. `Capabilities` counts it as checkout. `Buy#webmcp_flow`, when the page has no `create_checkout`, goes `create_cart` → hand-off tool → reads the checkout URL (the tool's result if it returns one, otherwise the tab's `location.href` through the bridge after it navigates) → `webmcp_handoff_report`, which auto-opens it through `CheckoutHandoff`. `reconcile_checkout` runs against `get_cart`, since no checkout document exists.
- Live check for the hand-off: does a Shopify checkout URL taken from the bridge's browser still hold the cart when it's opened in the shopper's own browser? If not, the hand-off has to stay in the bridge's browser (headed), and Phase 3 depends on that too. Record the answer in the design log.
- Live check before merging: rerun the 2026-09-23 storefront sweep with `preset: :auto`, then record the result and the fingerprint's date in the design log. Shopify can change its tool set without warning; when the fingerprint misses, the page falls to Phase 2, not to a wrong mapping.

### Phase 2: schema matching for unknown pages, confirmed by the user

- `WebMcp::Matcher.propose(tools)` returns a proposed `tool_names:` hash plus a confidence and reason for each entry. It scores tools by name similarity (tokenized: `findProducts` ↔ `search_catalog`), by input schema shape (a `query` string → search; `product_id`/`variant_id` + `quantity` → add to cart), and by the `readOnlyHint` annotation.
- No LLM in the gem. An agent caller can do its own matching and pass `tool_names:`; the `shop-via-ucp` skill documents how.
- **Read actions** (`search_catalog`, `get_product`, `get_cart`) can be used after a proposal with no confirmation, since a wrong match there wastes a call but changes nothing.
- **Mutating actions** (`create_cart`, `update_cart`, `create_checkout`, anything with `consequentialHint`) need confirmation before the first call. In the CLI that's a prompt listing the proposed tool, its description quoted as page content, and its schema. Under `--json`, or with no TTY, the run stops with outcome `webmcp_mapping_unconfirmed` and returns the proposal for the caller to pass back as `tool_names:`.
- **A confirmed mapping is shared (decision 3).** It's stored in `~/.portage/webmcp_mappings.json` keyed by the page's tool fingerprint (sorted tool names plus a hash of each input schema), with the origins it has been seen on kept as metadata only. Any later page with the same fingerprint reuses it with no prompt, which in effect makes it a local preset. A page whose schemas differ gets a different fingerprint and has to be confirmed again, so a lookalike page can't borrow a mapping with a different shape.
- Stretch: `portage webmcp mappings export`/`import`, so a shared file can seed built-in presets upstream. Contributing back is the path to coverage beyond one machine.

### Phase 3: approved autofill of the store's checkout

- Opt-in, per run: `--autofill` or `PORTAGE_WEBMCP_AUTOFILL=approve`. Off by default. Even with it on, the shopper approves in the prompt what will be entered, and where, before anything is typed.
- Scope: contact email and shipping address from `PORTAGE_SHIP_*`/buyer context, plus choosing the cheapest shipping rate (or the one set by config). **Never payment fields, never card or account data, never the pay button.** The run stops on the payment step and hands off as `express_stop`.
- Mechanism: the same bridge's browser (the one with the cart), driven through `ScriptEvaluator`, filling fields found by `autocomplete` attribute (`email`, `shipping given-name`, `address-line1`, `postal-code`, …). Per-platform selectors live in the preset as a fallback. Fields that can't be matched are left for the shopper and listed in the report.
- The browser has to be visible to the shopper so they can pay (see the Phase 1 live check). Headless runs report `autofill_needs_headed_browser` and hand off as they do today.
- Stop at bot challenges. A CAPTCHA or challenge page ends autofill with `autofill_blocked`; it's never solved or bypassed.
- Checkout pages are untrusted content. Autofill never follows instructions or links on them and only writes the approved values into fields that match.

### Phase 4: docs

- README "Stores that don't run Portage": presets, `preset:`, the matcher, and the confirm rule.
- Update the `shop-via-ucp` skill: WebMCP ranks after native UCP and before platform adapters when a browser is available, and it always ends in a hand-off.
- Design-log entry for Phase 0's bug and for the fingerprint rule.

## Out of scope

- Completing payment over WebMCP (see [handoff-reconcile.md](handoff-reconcile.md) Phase 4 and [agentic-payments.md](agentic-payments.md)).
- Getting past bot walls or CAPTCHAs on storefronts. A page behind a challenge is reported as `webmcp_error` and left to the user.
- Giving `portage buy` a browser of its own from the shell. A shell run still needs an injected bridge, and a `--browser` flag that launches Ferrum is its own plan.
- Scraping or DOM automation for pages that register no tools.

## Open questions

1. Phase 0: count a hand-off-only checkout tool as advertising checkout? (Recommended: yes, see above.)
2. ~~Phase 2: shared or per-origin mappings?~~ Shared by fingerprint (decision 3).
3. Phase 1 live check: does the checkout URL survive a move to another browser? The answer decides whether hand-off opens in the shopper's browser or stays in the bridge's.

## Progress log

| Date | Phase | Result |
|---|---|---|
| 2026-09-28 | 0 | Shipped. `WebMcp::Capabilities`, `Transport#answers?`, `connect` derives capabilities. webmcp 137 examples green, cli 450 green, rubocop clean on both. Not committed. |

### Next session: Phase 1

Paste into a fresh session:

> Implement Phase 1 of `docs/plans/webmcp-universal-outbound.md` (platform presets and the hand-off checkout path). Read the plan's Context, Decisions, Phase 0 and Phase 1 first. Phase 0 is in the working tree. Stop after Phase 1: run both suites and rubocop, update the progress log, and write the Phase 2 hand-off prompt.
