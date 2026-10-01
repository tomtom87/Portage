# Portage for OpenClaw

An [OpenClaw](https://docs.openclaw.ai) plugin that gives an agent typed `portage_*` tools over the [Portage](https://github.com/tomtom87/Portage) CLI: find products across online stores, compare them, price a checkout with a dry run, and buy only after you have approved the exact total. It also bundles the `buy` and `shop-research` skills and a short skill that maps each step of the buy flow to its tool.

The CLI is the only engine. Every tool runs `portage <subcommand> --json` (an argument array, never a shell) and returns the JSON. Spending limits, approval and payment enrolment stay in Portage; the plugin can't loosen them.

## Requirements

- OpenClaw 2026.5.28 or newer (the first release whose command helper caps output; see the safety model).
- `portage-cli` 0.12.0 or newer on your PATH (the plugin checks once and says so if it is older):
  - `brew install tomtom87/portage/portage` (macOS and Linux; `brew upgrade portage` to upgrade), or
  - `gem install portage-cli` (any Ruby 3.2 or newer; `gem update portage-cli` to upgrade).
- Node 24 or newer to build or develop the plugin.

Run `portage setup` yourself in a terminal first (shipping address, search keys, payment method, spending caps). The agent can read `portage_doctor` to see what is missing, but it can't set any of that up.

## Install

From ClawHub:

```bash
openclaw plugins install clawhub:tomtom87/portage
```

From a local checkout (build first, see Development):

```bash
openclaw plugins install --link ./openclaw-plugin
```

## Enabling the optional tools

The read-only tools are on by default. The tools that price, approve, buy, hand off or edit the index are optional: OpenClaw leaves them off until you allow them. Allow the ones you want, for example `portage_dry_run`, `portage_approve`, `portage_buy_quote` and `portage_handoff` for buying, in your OpenClaw tool settings (see [plugin tools](https://docs.openclaw.ai/tools/plugin)). If the agent needs one that is off, it will tell you which, and it won't try to get round it with a shell.

## Config

Set these under the plugin's config in OpenClaw:

| Key | Default | What it does |
|---|---|---|
| `portageBin` | `portage` | Path or name of the `portage` executable. It must be `portage` itself, or a path ending in `/portage`: the plugin refuses to start anything else. |
| `timeoutSeconds` | `120` | Per-call timeout. Index builds and `--wait` hand-offs get a longer fixed ceiling of their own. |

## Tools

On by default:

| Tool | Does |
|---|---|
| `portage_doctor` | Reports what is set up and what is missing. |
| `portage_find` | Searches stores for a product; returns offers and a `search_id`. |
| `portage_find_store` | Searches one named store's live catalogue. |
| `portage_check` | Says whether Portage can buy from a store (`automated`, `webmcp`, `handoff`, `unsupported`). |
| `portage_compare` | Compares a product across stores. |
| `portage_index_search`, `portage_index_show`, `portage_index_sources` | Read the local store and product index. |
| `portage_history` | Past purchases and searches. |
| `portage_orders_reconcile` | Tracks hand-offs you finished in the browser. |
| `portage_policy_show` | Shows your spending policy. |
| `portage_payment_list` | Lists enrolled payment methods (labels only). |
| `portage_browser_profile_status` | Status of Portage's dedicated browser profile. |

Optional (you enable them):

| Tool | Does |
|---|---|
| `portage_pick` | Lets you choose the store; opens a product page in your browser on request. |
| `portage_dry_run` | Prices a purchase and saves a quote (`qt_...`). Charges nothing. |
| `portage_approve` | Shows a quote for approval, or records your yes (`relayed_yes: true`). |
| `portage_buy_quote` | Buys one approved quote. The only tool that can spend money. |
| `portage_handoff` | Builds the cart and gives you the checkout to pay yourself. |
| `portage_index_add`, `portage_index_remove`, `portage_index_build`, `portage_index_refresh` | Edit or rebuild the local store index. |
| `portage_browser_import` | Previews, then (with `confirm: true`) saves shop domains found in your browser bookmarks and history. |

## Safety model

1. **You approve every payment.** No tool can pass `--yes` on a store URL or an offer. The one buying tool, `portage_buy_quote`, buys a saved quote, and Portage refuses unless you have approved that quote under your `require_approval` policy.
2. **A yes is only relayed once you have given it.** `portage_approve` takes `relayed_yes`, false by default, and the tool text says it may be true only after you approved that exact total in chat. Under `require_approval: person`, only a yes you type in your own terminal counts.
3. **No tool can loosen your limits or touch credentials.** The plugin doesn't expose `policy set`, `payment enroll|remove|revoke|freeze|set-default`, `history clear`, `setup`, `generate`, `--payment-token`, `--via`, proxy flags or the decision-check flags, and it never reads `~/.portage/.env`, `policy.json` or `quotes/`. Tests pin this for every tool with injection strings.
4. **Store and product text is untrusted.** Results are passed through as data; the tool descriptions and skills tell the agent never to follow instructions in them.
5. **Buying tools are opt-in.** Nothing that prices, approves, buys or changes the index runs until you enable it.
6. **No direct checkout.** The bundled `buy` skill leaves out its "no CLI" fallback (`references/raw-ucp.md`, which has the agent create and pay a store's checkout over raw UCP itself). In its place the skill, and `portage-openclaw`, tell the agent to stop and ask you to install `portage`, and never to drive a store's checkout or payment with a shell, web fetch or browser. So every payment passes Portage's policy, approval and checkout-mismatch checks.
7. **The only subprocess is `portage`, and OpenClaw starts it.** Every tool runs the `portage` executable on your machine. The plugin has no `child_process` code of its own: `src/runner.ts` hands the argument array to `api.runtime.system.runCommandWithTimeout`, the helper OpenClaw gives plugins for running a native command, which always spawns without a shell, so tool input is never parsed by one. Each call has a per-call timeout, a 16 MB output cap (output past it is an error, not a partial result) and an empty stdin, and runs only when `portageBin` names the `portage` executable; anything else is refused before it starts. Tests run the runner against OpenClaw's real helper and pin all of this. Up to 0.10.2 the runner called Node's `child_process.execFile` itself, with the same limits, which ClawHub's scan reported as shell execution.

A non-zero exit from the CLI is not an error on its own: outcomes such as `needs_approval` or `quote_changed` come back as results. Only unparseable output or a failure to start `portage` is a tool error.

## Bundled skills

The plugin ships three skills in `skills/`:

- `buy` and `shop-research`: copies of the Portage skills in `plugins/buy/skills/`, made at build time. They remain the source of truth for the flow and the judgement calls. The copy of `buy` drops the raw-UCP "no CLI" fallback (see the safety model).
- `portage-openclaw`: written for this plugin. Maps each CLI step to its tool and restates the approval rules.

`npm run build` copies the first two (they are gitignored here) and `npm pack` includes all three.

## Development

```bash
cd openclaw-plugin
npm ci
npm run build       # copies the skills, then compiles src/ to dist/
npm test            # vitest, against a fake portage script
npm run typecheck
```

The tests run every tool against a fake `portage` that records its arguments, so none of them touch a real store or your Portage data. The plugin hasn't been exercised against a live OpenClaw gateway yet.
