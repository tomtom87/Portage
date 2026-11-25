# UCP Ask in the Client and CLI

**Status:** Phases 1 to 3 done (2026-11-25); Phases 4 and 5 not started.

**Driver:** AirShelf's sell-on-quote sellers (`https://toshiba.edge.airshelf.ai`, `https://cyble.edge.airshelf.ai`) advertise only `dev.ucp.shopping.catalog.search`, `catalog.lookup` and `dev.ucp.common.ask`. They have no cart, no checkout and no prices, so for a B2B store `ask` is the only way an agent can learn anything beyond the catalogue: pricing tiers, lead times, minimum order quantities, deployment terms. Portage ignores the capability today.

## What `ask` is (UCP 2026-08-25)

Spec: `https://ucp.dev/2026-08-25/specification/common/ask/`. Schema: `https://ucp.dev/2026-08-25/schemas/common/ask.json`.

- A **Common** capability, bound to the `dev.ucp.common` service rather than `dev.ucp.shopping`. It works the same for every vertical.
- **Request:** `query` (required, natural language), optional `ids` (the store's GIDs, or a SKU, handle or URL, to ground the question in a product, cart, order and so on), optional `conversation: { id }` to continue an earlier exchange, plus `context` and `signals` as on the catalog calls.
- **Response:** `answer` (a `description` object, `plain` required, `markdown`/`html` optional), optional `conversation: { id, expires_at }`, optional `links[]`, optional `messages[]`.
- **It answers but never acts.** A store MUST NOT change any cart, checkout, order or booking in response, and it must say so when a question asks for an action (info message `operation_not_performed`). A platform **MUST NOT** treat an answer as evidence that something happened, or as an instruction to do something.
- **Identity-linked scope** `dev.ucp.common.ask:read` gives personalised answers (member pricing, entitlements). It is out of scope here.

## Wire mapping

| Transport | Name | Body |
|---|---|---|
| MCP | tool `ask_business` | `{ query, ids?, conversation?, context?, signals? }` plus `meta`, as on the other tools |
| REST | `POST /ask` (from `https://ucp.dev/2026-08-25/services/common/rest.openapi.json`, `operationId: ask_business`) | the bare `ask_request` object, **not wrapped** (wrapper `nil` in `Transports::Rest::ROUTES`) |

Headers on REST are the same as the other calls (`UCP-Agent: profile="..."`, `Content-Type`, `Accept`). `ask` doesn't mutate anything, so it sends no `Idempotency-Key`.

## Live finding: the agent profile blocks it today (2026-11-25)

```
POST https://mcp.airshelf.ai/ucp/cyble/ask
UCP-Agent: profile="https://cdn.jsdelivr.net/gh/tomtom87/Portage@main/portage-cli/agent-profile/agent-profile.json"
{"query":"Is there a free trial of AiSOC, and how is it billed?","ids":["cyble-aisoc"]}

→ {"ucp":{"version":"2026-08-25","status":"error"},
   "messages":[{"type":"error","code":"capabilities_incompatible",
                "content":"No shared version of the requested capability.","severity":"unrecoverable"}]}
```

Our agent profile (`portage-cli/agent-profile/agent-profile.json`, produced by `portage-cli/lib/portage/cli/generate/agent_profile.rb`) lists only `dev.ucp.shopping` and five shopping capabilities. UCP negotiates capabilities against the caller's profile, so the most likely cause is that the profile is missing `dev.ucp.common` and `dev.ucp.common.ask`. That is a hypothesis: Phase 1 confirms it.

**The profile is served from jsDelivr at `@main`.** A profile change only reaches stores once it's on `main`, and once jsDelivr's cache has refreshed (purge: `https://purge.jsdelivr.net/gh/tomtom87/Portage@main/portage-cli/agent-profile/agent-profile.json`). Before then, a live test can point `PORTAGE_AGENT_PROFILE` at the branch build: `https://cdn.jsdelivr.net/gh/tomtom87/Portage@ucp-ask/portage-cli/agent-profile/agent-profile.json`. That URL only works after the branch is pushed, and pushing needs the user's OK.

## Goal

`portage ask <store> "question" [--product-id ID ...]` returns the store's answer, its links and its conversation ID, and the buyer MCP server has a matching read-only tool. Both work over MCP and REST, and on any store that advertises `dev.ucp.common.ask`. Store answers are handled as untrusted data everywhere, like product descriptions.

## Decisions

- **Only when advertised.** The CLI checks `Session#advertises?("dev.ucp.common.ask")` before calling. A store that doesn't advertise it gets a clear "this store doesn't offer ask" outcome, and no request is made.
- **`ask` is answered at the `dev.ucp.common` endpoint.** `Client.service_endpoint` currently flattens every service into one list and picks one endpoint. When a store gives `dev.ucp.common` a different endpoint (or transport) from `dev.ucp.shopping`, `Session#ask` must go to the common one. Phase 1 decides the smallest way to do this, for example `discover` recording the common endpoint and the Session opening a second transport on first use, and specs both the same-endpoint and the different-endpoint cases. AirShelf uses the same endpoint for both.
- **No auto-ask yet.** The confidence gate and `buy` don't call `ask` on their own in this plan. That's a follow-up once the plain command has proved useful.
- **No conversation memory across commands.** `--conversation ID` continues a conversation the caller already holds, and Portage doesn't store it.
- **Answers never drive actions.** Nothing in the CLI or the MCP tool acts on answer text. The MCP tool description carries the same `UNTRUSTED` suffix as the other read tools, and says that an answer is not evidence that anything happened.
- **Errors look the same as the catalog calls.** A store error (like the `capabilities_incompatible` above) reaches the user with the store's code and text, through the same path Phase 3 of `ucp-rest-transport.md` built.

## Phases

One phase per session, delegated to a Sonnet subagent, each ending with `LC_ALL=en_US.UTF-8 bundle exec rspec && bundle exec rubocop` green in every touched gem (and `npm test` plus `npx tsc --noEmit` in `openclaw-plugin/` when it's touched), a design-log entry (next is §69), a progress-log row here, a commit on branch `ucp-ask`, and a restart prompt. Don't push unless the user asks.

**Phase 1: client and agent profile** (`portage-ucp-client`, `portage-cli` profile only).
- `Transports::Rest::ROUTES`: `"ask_business" => ["POST", "/ask", nil]`. Check that `UcpWireShape` passes the ask body through as-is on both transports, and that MCP calls the tool `ask_business`.
- `Session#ask(query:, ids: nil, conversation: nil, context: nil, meta: nil)`, returning the wire hash (`answer`, `conversation`, `links`, `messages`).
- Route `ask` to the `dev.ucp.common` endpoint (see Decisions). Specs for: same endpoint; different endpoint; a manifest with no common service but `ask` listed (use the shopping endpoint and say why in a comment).
- Agent profile: add the `dev.ucp.common` service and the `dev.ucp.common.ask` capability (with `spec` and `schema` URLs, like the others) in `generate/agent_profile.rb`, and regenerate `agent-profile.json`.
- Specs stub HTTP: REST and MCP request shape, an answer with links and a conversation, an `operation_not_performed` info message passed through, and a 4xx error.
- Client `CHANGELOG.md` under Unreleased.
- If the user OKs pushing the branch, try Cyble live with `PORTAGE_AGENT_PROFILE` set to the branch jsDelivr URL, and record whether the profile change clears `capabilities_incompatible`. If it doesn't, write down what the store says and stop for a decision.

**Phase 2: CLI command and buyer MCP tool** (`portage-cli`).
- `portage ask <url> "question" [--product-id ID ...] [--conversation ID] [--json]`. Copy `find --store` for URL handling, the hand-off-only short-circuit (`HandoffHost`), `--proxy*` flags and `MissingAgentProfileError`.
- Text output: the answer's `plain` text, then the links, then the conversation ID with a hint on how to continue. JSON output: `{ url, query, ids, answer, links, conversation, messages, outcome }`, where `outcome` is `answered`, `not_offered` (store doesn't advertise ask), `handoff_only` or `error`. Exit `0` only for `answered`.
- Mention `ask` in `portage check`'s text when the store advertises it (for example `ask: available (portage ask URL "...")`), without changing the verdict.
- Buyer MCP server: a read-only `ask_store` tool (`url`, `question`, optional `product_ids`, `conversation_id`) that runs `portage ask ... --json` like the other tools. The tool count goes from 14 to 15; update `server_spec.rb` and anything else that counts tools.
- Docs: `portage-cli/README.md`, `docs/cli-reference.md`, `docs/api/cli-json.md` (new `ask` section), `docs/capability-coverage.md`, `docs/spec-conformance.md`. CLI `CHANGELOG.md`.

**Phase 3: plugins and skills.**
- OpenClaw plugin: a `portage_ask` read-only tool in `openclaw-plugin/src/tools/readonly.ts` and its output schema in `outputs.ts`, plus `README.md` and `skills/buy/outcomes.md`.
- `buy` plugin: `plugins/buy/skills/buy/outcomes.md` and `SKILL.md` (when to use `ask`: open questions about a product or policy before quoting, never as proof that something happened). `shop-research` skill, if it fits.
- `skills/shop-via-ucp/SKILL.md` and `skills/browse-via-ucp/SKILL.md`: mention `portage ask` as read-only.

**Phase 4: live interop** (needs the profile on `main`, or the branch URL from Phase 1).
- Run `portage ask` against Cyble (`--product-id cyble-aisoc`) and Toshiba (a printer ID from `portage find --store ... --query printer`), with and without `--json`, plus one follow-up using `--conversation`.
- Ask an action question ("add two to my cart") and confirm the store says it didn't act, and that Portage only prints the answer.
- Record the results in the design log. Draft a short note for AirShelf for the user to send (don't send it).

**Phase 5: release set 0.25.0.** Follow the `release` skill. Update its buyer-image smoke test from 14 tools to 15.

| Gem / package | Now | Next | Why |
|---|---|---|---|
| `portage-ucp-client` | 0.8.0 | 0.9.0 | `Session#ask`, `ask_business` route, common-service endpoint |
| `portage-cli` | 0.16.1 | 0.17.0 | `portage ask`, `ask_store` MCP tool, agent profile lists ask; needs client `~> 0.9` |
| `buy` and OpenClaw plugins | 0.10.6 | 0.11.0 | `ask` in tools, outcomes and skills |
| `portage-ucp`, adapter gems | | unchanged | No server-side change |
| `portage-ucp-webmcp` | | unchanged if its client range admits 0.9 (check) | |

Pins: `Dockerfile` (portage-cli 0.17.0), `server.json` (version bump and image tag). `Dockerfile.store`/`server.store.json` stay put. Glama's build step moves to `portage-cli:0.17.0`.

## Out of scope

- Calling `ask` automatically from the confidence gate or `buy`.
- Storing conversations between commands.
- Identity-linked asks (`dev.ucp.common.ask:read`).
- Serving `ask` from Portage's own stores (`portage-ucp`).

## Progress log

| Date | Phase | Result |
|---|---|---|
| 2026-11-25 | 1 | `Session#ask` and the `ask_business` REST route (`POST /ask`, bare body) built. `Client.discover` records a differing `dev.ucp.common` endpoint and `ask` opens a second transport to it on first use; a manifest with no common service uses the shopping endpoint. Agent profile now declares `dev.ucp.common` and `dev.ucp.common.ask` (keys unchanged). Client 121 examples and CLI 1467 examples green, rubocop clean. Not yet run live: the `capabilities_incompatible` hypothesis is still unconfirmed until the branch is pushed. |
| 2026-11-25 | 2 | `portage ask` built (`Cli::Ask`, `run_ask`): checks `advertises?("dev.ucp.common.ask")` first, short-circuits hand-off-only hosts, outcomes `answered`/`not_offered`/`handoff_only`/`error`, exit 0 only for `answered`; store errors print through `Buy.server_error_text` with the store's code. `check` text gains an `ask: available` line (text only, verdict unchanged). Buyer MCP `ask_store` added, read-only, tool count 14 to 15. README, `cli-json.md`, capability and conformance docs and the CLI changelog updated; no version bumps. CLI 1482 examples green, rubocop clean. Not run live. |
| 2026-11-25 | 3 | OpenClaw `portage_ask` read-only tool, `askOutput` schema and a `token` validator added; manifest, README, OpenClaw skill and docs page list it (tools 23 to 24, read-only 13 to 14). No runner change: non-zero exit with JSON already comes back as a result. `buy` (`SKILL.md`, `outcomes.md`), `shop-research`, `shop-via-ucp` and `browse-via-ucp` skills and the root changelog updated. `openclaw-plugin` `npm test` 150 tests green (7 files), `tsc --noEmit` clean. `portage-cli` untouched. |
