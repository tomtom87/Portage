# Agentic Commerce Roadmap: projects, cards, dashboard, phone

**Status:** Idea capture (2026-10-21). Nothing built. Local only for now (decision 1). Depends on [buyer-mcp-server.md](buyer-mcp-server.md) shipping first.
**Driver:** Portage should make e-commerce fully agentic for someone who only has a phone. The target user is a tradesperson (plumber, electrician) who needs many parts for a job. They give the agent a list, or let the agent interview them. The agent finds every part, works through picks and quotes with them, and keeps the job, so "the bathroom refit from last year" can be found and reordered.

## What the user asked for

1. **Demo in Claude and ChatGPT** where the tools return visual cards (offers, basket, quote, order), not just text.
2. **HTML dashboard with a full onboarding wizard.**
3. **Shopping list or interview.** Paste a list, or answer the agent's questions about the job and let it build the list.
4. **Bulk sourcing.** Find every item, pick per item, quote per store, buy or hand off.
5. **History by project.** Jobs, what was bought for each, and a reorder.
6. **Works on Android alone**, with no laptop, terminal or Ruby.

## The fork that decides everything: local vs hosted

The buyer MCP server is planned as **local stdio only** (its non-goals rule out an HTTP transport). That covers Claude Desktop and Claude Code on a computer. It does **not** reach:

- ChatGPT, which connects only to remote HTTPS MCP servers;
- the Claude and ChatGPT Android apps, which also use remote connectors only;
- a phone-only user, who has nowhere to run `portage`.

So items 1 (ChatGPT half) and 6 need a **hosted buyer server**: Streamable HTTP transport, OAuth sign-in, and per-user storage behind the existing storage abstraction ([storage-abstraction-journal.md](storage-abstraction-journal.md)) instead of `~/.portage` files. The phone user then adds one connector URL in the Claude or ChatGPT app, and opens the dashboard as a web page they can add to the home screen.

**Decided 2026-10-21: local only for now.** Everything is built and demoed on Claude Desktop and Claude Code over stdio. The hosted server, the ChatGPT demo and the Android path are deferred to a later plan.

**The hosted server is the premium version of Portage.** The open-source CLI and the local buyer server stay free and complete: projects, sourcing, cards and dashboard all work on the shopper's own machine. Premium is us hosting the same thing, for people who only have a phone or want ChatGPT. They sign in, add one connector URL, and use the dashboard as a home-screen web page. They don't install anything. What premium covers beyond hosting (sync between devices, team accounts, price tracking) is for its own plan. Until then, the dashboard and cards should not assume a single local user anywhere that would be hard to undo, so per-user storage can slot in later. If hosting comes back, the starting point is **hand-off only**: the shopper pays on the store's own checkout in their phone browser, and Portage never holds a card or spends on a hosted server. The alternative, Termux on Android, runs the local CLI on the phone but fails "very easy and accessible".

## Pieces

### A. Projects (new core concept)

A project is a named job with a list of items. Each item has a description, quantity, optional spec (size, rating, brand, part number) and a status: `open → found → picked → quoted → bought | handed_off | skipped`. It links to the searches, quotes and order ids it produced. Projects are stored in `~/.portage/projects.json` locally, and through the storage abstraction when hosted.

- CLI: `portage project new|list|show|add|edit|archive|reorder`, all with `--json`.
- `project show` reuses `OrderHistory` (buyer MCP Phase 1) for the orders linked to each item.
- **Reorder** copies a past project's items into a new project with status `open`. It never re-buys directly.

### B. Interview and list intake: agent behavior, not code

The interview is a **prompt**, not a tool. The buyer MCP server exposes MCP `prompts` (`plan_project`, `paste_shopping_list`), and the Claude plugin's `buy` skill gets the same text. The prompt tells the agent to:

- ask about the job (trade, type of work, rooms or fixtures, existing system, region and standards);
- draft the list with quantities;
- read it back for the shopper to correct;
- only then write it with the project tools.

Pasting a list goes through the same read-back. No NLP in Ruby: the agent parses, Portage stores.

### C. Bulk sourcing

`portage project source ID` runs `find` for each open item, records offers per item, and proposes a **basket per store**: fewest stores that cover the list within the caps, with shipping where known. The shopper picks per item, or accepts the suggested basket. Quotes are then one per store, and approval stays per quote, so the shopper sees every real total before money moves.

Reality check: most trade suppliers (Screwfix, Toolstation, Ferguson, Home Depot Pro) are not UCP stores. Expect most trade baskets to end in **hand-off**, with the cart prefilled where the store supports it and a checklist otherwise. Sourcing must still be useful when nothing can be bought automatically.

### D. Cards: MCP Apps, shared by Claude and ChatGPT

Claude and ChatGPT both render **MCP Apps**: tool results that point at a `ui://` HTML resource drawn inline in the chat. One set of cards works in both:

| Card | From tool | Shows |
|---|---|---|
| Offers | `find_products`, `compare_prices` | Product, store, price, stock, "pick" button |
| Project | project tools | Items with status chips, progress |
| Basket | `project source` | Stores × items, totals, gaps |
| Quote | `quote_purchase` | Exact total, store, items; "approve" sends the shopper's yes as a chat message |
| Orders | `list_orders` | Past orders grouped by project |

Rules:

- The cards are plain HTML and JS in `portage-cli`, served as MCP resources. The text and `structuredContent` output stays complete, so hosts without UI lose nothing.
- **A card button never approves or buys by itself.** It sends a message in the chat, and the existing `approve --via agent` / `buy --quote` gate applies unchanged.
- Verify at phase start that the Ruby `mcp` gem can return tool `_meta` and `ui://` resources. If it can't, patch it upstream rather than fork.

### E. HTML dashboard and onboarding wizard

`portage dashboard` serves one local page on `127.0.0.1` with a random per-run token in the URL, and opens it in the browser.

- **Onboarding wizard** follows `setup_wizard`'s steps in the same order: shipping, search keys, agent profile, approval level and caps, index build (with progress), browser import (local only). It ends with **"Connect to Claude / ChatGPT"**, which shows the exact config or connector URL to paste, with a copy button.
- **Projects:** create, edit, paste a list, see sourcing state, reorder.
- **Orders:** the `orders list` view, filterable by project.
- **Approvals:** a quote waiting on `require_approval person` can be approved here. This is a real person surface (`--via web`), alongside `tty`.
- Policy and payment enrollment stay CLI-only at first, the same boundary as the MCP server.

This reverses the 2026-09-29 decision in [human-pick-and-approve.md](human-pick-and-approve.md) ("No local web page for now. If one comes later, keep it simple"). Keeping it simple means one HTML file, no build step, no framework, and only the existing CLI `--json` calls behind a tiny Rack/WEBrick handler.

### F. Demo

A plumber's bathroom refit runs end to end. The interview builds the list, sourcing fills a basket across stores, the shopper approves one UCP quote and buys it, and the rest go to hand-off. A year later, "reorder last year's bathroom job" brings the project back.

- Recorded in **Claude Desktop** after Phase 3, with the dashboard added after Phase 4. The ChatGPT and Android recordings wait for the deferred hosted server.
- Uses a seeded demo store set: the Shopify dev store and known UCP stores, so the recording is repeatable.

## Phases (after buyer MCP Phases 1–5)

One phase per session, as usual.

1. **Projects:** data model, `portage project` CLI, history and reorder, specs.
2. **Bulk sourcing and MCP project tools:** `project source`, the basket proposal, project tools on the buyer server, and the `plan_project`/`paste_shopping_list` prompts. This breaks the 15-tool cap unless project actions merge into one or two tools; see decision 3.
3. **Cards:** MCP Apps resources for the five cards, `_meta` wiring, and a Claude Desktop demo recording.
4. **Dashboard and onboarding wizard:** `portage dashboard`, the wizard, projects, orders, and `--via web` approvals.
Deferred, not scheduled: **hosted buyer server (premium)**. It would cover Streamable HTTP, OAuth, per-user storage, hand-off only, the dashboard behind sign-in, connector docs for Claude and ChatGPT on Android, and the ChatGPT and Android demo.

## Open decisions

1. **Hosted service. Decided 2026-10-21: local only for now.** A hosted service is the only way to reach ChatGPT and phone-only users. It brings accounts, hosting cost, privacy duties for shoppers' addresses and order history, and abuse limits. When it comes, it is the premium, paid tier, and the local version stays free. Revisit after Phase 4.
2. **Reverse "no local web page".** The dashboard needs it. Recommend yes, within the one-file limit above.
3. **Tool cap.** Either raise it from 15 to about 18, or merge project actions into `manage_project` (create, add items, edit, archive, reorder) plus `source_project`. Recommend the merge: two tools, cap kept.
4. **Approval from cards.** Recommend the card sends a chat message and never calls `approve` itself (kept above). A one-tap approve inside the card would be smoother, but it lets the model's UI stand in for the person.
5. **Trade suppliers.** Is there a target list (UK vs US) to check for UCP support, or for a hand-off cart prefill, before Phase 2?

## Explicit non-goals (for now)

- Any hosted or remote server, ChatGPT support, and the Android path (deferred, see decision 1).
- Storing cards anywhere.
- A native Android app. The phone path is the Claude or ChatGPT app plus the web dashboard.
- Price tracking, scheduled reorders, or team accounts for a firm with several tradespeople.
- Parsing lists or interviewing in Ruby. That is the agent's job.

## Progress log

| Phase | Date | Summary | Design log |
|-------|------|---------|------------|
