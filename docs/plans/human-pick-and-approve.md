# Human pick and approve: a built-in interface for loop steps 3 and 5

## Context

`docs/agentic-flow.md` "The loop" leaves two steps as `(your UI)`:

- **Step 3, person picks** the store from `find`'s `offers[]`.
- **Step 5, approve**: the person says yes to the exact dry-run total.

Level 2 integrators build both themselves (`ask_person_to_approve` in the Ruby sample).
Level 1 (the `buy` skill) has no interface at all: steps 3 and 5 are prose rules in
`plugins/buy/skills/buy/SKILL.md`, and the skill runs with a shell, so nothing stops the
model from picking a store itself or passing `--yes` without asking.

### What exists today

| Piece | Where | Covers | Gap |
|---|---|---|---|
| Numbered pick prompt | `cli.rb` `buy_from_search` → `pick_offer` / `prompt_for_offer` | Step 3, for a human at a TTY running `portage buy --query` | Never fires for an agent (`--json` or no TTY); no pick for `find` output |
| `buy` refuses `--yes` without a store | `cli.rb` `buy_from_search` | Stops a *ranker* choosing the store | Doesn't stop a *model* naming one |
| `needs_confirmation` pattern | `cli.rb` `run_browser_import` | Model for "no TTY → report, don't act" | Only `browser import` uses it |
| Spending caps / allowlist | `portage policy set` | Backstop | Not an approval |

So: no interface an agent can hand to the person, and no link between the total the
person saw and the total `--yes` charges.

## Goal

Give every level a ready-made step 3 and step 5, CLI and agent only (no native dialogs,
no local web page), and keep `(your UI)` as a supported option for integrators who want
their own.

## Decisions (2026-09-29)

- `--require-approval` defaults to `any`, so nothing breaks.
- No dialog tools on any OS. Surfaces are `tty` and `agent` only.
- Quotes don't expire. Any price increase on the real run refuses the buy.
- The pick offers "compare this across stores" as a choice.
- Whenever the agent asks, the person can open the suggested product page first.
- No local web page for now. If one comes later, keep it simple.

## Design

### 1. Stable offer references (`find`)

Each `offers[]` entry gains `offer_ref`: a short opaque id (e.g. `of_3f9a1c`) saved with
the search in history (store, product_id, title, amount, currency, found_at). Lets a pick
or a quote point at one offer without re-sending store/product_id/query. `buy --offer REF`
resolves it. Additive field, no breaking change.

### 2. Quotes (step 4 → 5 link)

`buy ... --dry-run --json` gains `quote_id` and saves a quote to `~/.portage/quotes/`:
offer_ref, store, product_id, qty, total, currency, created_at, `approved: false`.

`buy --quote QUOTE_ID --yes` buys that quote. Before charging it re-prices and refuses
with a new outcome `quote_changed` if the new total is higher than the quoted one (the
report carries both totals). Quotes don't expire. Each is single use: consumed on
`purchased` or any hand-off.

### 3. Prompt surfaces

One small `HumanPrompt` used by both commands, injectable for specs:

- `tty`: reads and writes `/dev/tty`, so it works when stdout is piped to an agent.
  Extends today's `prompt_for_offer`. Fails cleanly with no controlling terminal.
- `agent`: prompts nobody. Returns a `needs_*` outcome with render-ready `choices[]`
  for the agent to show in its own UI (Claude Code: `AskUserQuestion`; others: a
  numbered list).
- `--via auto` (default): `tty` if there is a controlling terminal and not `--json`,
  else `agent`.

A `tty` answer is recorded as `by: "person"`; a relayed answer as `by: "agent_relayed"`.

**View the product page.** Whenever the agent asks, the person can open the store's page
for what's being suggested before answering:

- Every `choices[]` entry and every `needs_approval` summary carries `url`, the offer's
  product page as `find` returned it. The agent shows it as a link next to the choice.
- `tty`: typing `v N` (pick) or `v` (approve) opens that page in the browser, then shows
  the same question again. Viewing never counts as an answer.
- `portage pick --view REF` and `portage approve QUOTE_ID --view` open the page from any
  shell or agent. They're read-only: no pick, no approval.
- Opening reuses `CheckoutHandoff`'s `open`/`xdg-open` shell-out (array form). Only
  `http(s)` URLs on the offer's store host are opened. Any other URL is refused with
  `view_refused`, since store data is untrusted.

### 4. `portage pick` (step 3)

```bash
portage pick [--search LAST|SEARCH_ID] [--via auto|tty|agent] --json
```

Shows the offers from a saved search plus one extra choice, "Compare an offer across
stores" (runs `portage compare` on the chosen offer, then shows the pick again with its
results). Returns
`{ "outcome": "picked", "offer_ref": "...", "store": "...", "product_id": "...", "by": "person" }`,
`"outcome": "cancelled"`, or `"outcome": "needs_pick"` with `choices[]`. The agent relays
a `needs_pick` answer with `portage pick --choose REF`.

### 5. `portage approve` (step 5) and the approval policy

```bash
portage approve QUOTE_ID [--via auto|tty|agent] [--relayed-yes] --json
```

Shows title, store, qty and total (formatted from minor units) and asks yes/no. A `tty`
yes marks the quote `approved_by: "person"`. `agent` returns `needs_approval` with a
summary; the agent relays the answer with `--relayed-yes` (`approved_by: "agent_relayed"`).

`portage policy set --require-approval person|any|off`, default `any`:

- `off`: today's behaviour, `--yes` alone buys.
- `any`: `--yes` needs `--quote` with an approved quote, person or relayed.
- `person`: only a `tty` approval counts. This holds even when the agent has a shell,
  since the model can't type on `/dev/tty`.

A refused run returns `needs_approval` with the quote id and never buys. Lowering
`--require-approval` needs a `tty` confirmation, so the model can't lower it.

### 6. `buy` skill and docs

- `plugins/buy/skills/buy/SKILL.md`:
  - Step 3: `portage pick --json`. On `needs_pick`, show `choices[]` with the host's
    structured question tool if it has one (Claude Code: `AskUserQuestion`, max 4
    options, "Other" shows more), else a numbered list, then `pick --choose REF`.
    Continue with `buy --offer REF --dry-run`. Show each choice's `url` as a link, and
    run `pick --view REF` if the person asks to see one.
  - Step 5: `portage approve QUOTE_ID --json`; relay only on `needs_approval`, with the
    product link (`approve --view` on request). Then `buy --quote QUOTE_ID --yes`.
  - Preflight: suggest `--require-approval person` when the person runs the agent from a
    terminal.
  - `references/outcomes.md`: `needs_pick`, `needs_approval`, `quote_changed`.
- `docs/agentic-flow.md` loop table: steps 3 and 5 become
  "`portage pick --json` / `portage approve QUOTE_ID --json`, or your UI"; step 6 becomes
  `buy --quote QUOTE_ID --yes`. The tool list gains optional `pick_offer` / `approve_quote`
  tools and `purchase` takes `quote_id`. Checklist gains `--require-approval person`.
- `docs/api/cli-json.md` (`pick`, `approve`, `--view`, quote fields, new outcomes including
  `view_refused`, Non-TTY section),
  `docs/skills/buy.md`, `docs/cli-usage-tutorial.md`, both CHANGELOGs.

## Phases

One phase per session (see memory: phased work via Sonnet subagent). Each ends with
suites + rubocop green, a progress-log row, a commit on `human-pick-and-approve`, and a
restart prompt.

| Phase | Scope | Files (main) |
|---|---|---|
| 1 | Data: `offer_ref` on `find` + history, `buy --offer`, quotes (`quote_id`, `--quote`, `quote_changed`, single use) | `cli/find.rb`, `cli/history.rb`, `cli/buy.rb`, new `cli/quotes.rb`, `cli.rb` |
| 2 | Interface: `HumanPrompt` (`tty`/`agent`), `portage pick` (with compare choice), `portage approve`, `--view` / `v` product-page viewing (same-host check), `--require-approval` policy | new `cli/human_prompt.rb`, `cli/pick.rb`, `cli/approve.rb`, policy code, `cli.rb` |
| 3 | Skill and docs: `buy` skill + references, agentic-flow, cli-json, tutorial, skills page, CHANGELOGs | `plugins/buy/**`, `docs/**` |

## Later

- A simple local web page for pick/approve, for agents with no terminal. Out of scope now.

## Progress log

| Date | Phase | Result |
|---|---|---|
| 2026-09-29 | 1 | `find` offers carry `offer_ref` (saved in history); `buy --offer REF`; `--dry-run` saves a quote in `~/.portage/quotes/` and returns `quote_id`; `buy --quote ID --yes` caps Buy at the quoted total, refusing `quote_changed` on the real run if higher, single use; specs. |
| 2026-09-29 | 2 | `HumanPrompt` (`tty` on /dev/tty, `agent`, `--via auto`; `no_terminal` when none); `portage pick` (`needs_pick`/`picked`/`cancelled`, `--choose`, compare choice + `--compare`, `search_id` on find/compare, compare offers saved with refs); `portage approve` (`needs_approval`/`approved`, `approved_by` person/agent_relayed; under `person` a relayed yes isn't recorded and the agent is sent to the person's terminal); `--view`/`v` open same-host http(s) pages or `view_refused`; `policy set --require-approval` (default `any`, stored in policy.json, lowering needs a tty yes) gates a real `buy --yes` into a dry run + `needs_approval`; shared `Money`/`BrowserOpener`; specs. |
