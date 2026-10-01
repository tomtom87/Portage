# OpenClaw plugin

A native [OpenClaw](https://docs.openclaw.ai) plugin that gives an agent typed `portage_*` tools over the `portage` CLI, in place of putting `portage` shell commands together from the [`buy`](buy.md) skill's text. It bundles the `buy` and [`shop-research`](shop-research.md) skills and adds a short third skill, `portage-openclaw`, that maps each step of the buy flow to its tool. It sits on top of the same CLI as every other agent route, so the CLI's spending policy and approval checks apply unchanged.

The plugin's own [README](https://github.com/tomtom87/Portage/blob/main/openclaw-plugin/README.md) has the full tool tables. This page covers what you need to install and run it.

## Install

You need OpenClaw 2026.5.28 or newer and `portage-cli` 0.12.0 or newer on your `PATH`. The plugin checks the CLI version once and says so if it is older.

```bash
brew install tomtom87/portage/portage   # macOS and Linux; brew upgrade portage to upgrade
# or
gem install portage-cli                 # any Ruby 3.2 or newer; gem update portage-cli to upgrade
```

Run `portage setup` yourself in a terminal first (shipping address, search keys, payment method, spending caps). The agent can read `portage_doctor` to see what is missing, but it can't set any of that up.

Then install the plugin from ClawHub:

```bash
openclaw plugins install clawhub:tomtom87/portage
```

To install from a local checkout instead, build it first (`npm ci && npm run build` in `openclaw-plugin/`, Node 24 or newer) and use `openclaw plugins install --link ./openclaw-plugin`.

## Config

Set these under the plugin's config in OpenClaw:

| Key | Default | What it does |
|---|---|---|
| `portageBin` | `portage` | Path or name of the `portage` executable. It must be `portage` itself, or a path ending in `/portage`: the plugin refuses to start anything else. |
| `timeoutSeconds` | `120` | Per-call timeout. Index builds and `--wait` hand-offs get a longer fixed ceiling of their own. |

## Read-only and opt-in tools

The read-only tools are on by default: `portage_doctor`, `portage_find`, `portage_find_store`, `portage_check`, `portage_compare`, `portage_index_search`, `portage_index_show`, `portage_index_sources`, `portage_history`, `portage_orders_reconcile`, `portage_policy_show`, `portage_payment_list` and `portage_browser_profile_status`. They search and report; none of them prices a purchase, buys, or writes anything.

The tools that price, approve, buy, hand off, open a browser or change the index are optional, and OpenClaw leaves them off until you allow them in its tool settings (see [plugin tools](https://docs.openclaw.ai/tools/plugin)): `portage_pick`, `portage_dry_run`, `portage_approve`, `portage_buy_quote`, `portage_handoff`, `portage_index_add`, `portage_index_remove`, `portage_index_build`, `portage_index_refresh` and `portage_browser_import`. To buy, you typically allow `portage_dry_run`, `portage_approve`, `portage_buy_quote` and `portage_handoff`.

The guardrails are the CLI's, and the plugin can't loosen them:

- No tool passes `--yes` on a store URL or an offer. The one buying tool, `portage_buy_quote`, buys a saved quote, and Portage refuses unless you have approved that quote under your `require_approval` policy.
- `portage_approve` only relays a yes (`relayed_yes: true`) after you approved that exact total in chat.
- Spending policy, payment enrolment, history clearing and setup are not exposed at all, and the plugin never reads `~/.portage/.env`, `policy.json` or `quotes/`.
- Store and product text is passed through as untrusted data.
- The only program the plugin runs is `portage`, and OpenClaw's own command helper starts it: an argument array, never a shell, with a timeout and an output cap.

See [You pick the store and approve the total](buy.md#you-pick-the-store-and-approve-the-total) for the flow, and the [security model](https://github.com/tomtom87/Portage/blob/main/openclaw-plugin/README.md#safety-model) in the plugin README for the pinned guardrails.

## Bundled skills

The plugin ships three skills:

- [`buy`](buy.md) and [`shop-research`](shop-research.md): copies of the Portage skills, made at build time, so the flow and the judgement calls stay in one place. The copy of `buy` leaves out its [raw UCP fallback](references/raw-ucp.md), which has the agent create and pay a checkout itself outside Portage's checks; in OpenClaw the skill says to stop and ask the user to install `portage` instead.
- `portage-openclaw`: written for this plugin. It maps each CLI step in the buy flow to its tool, tells the agent to prefer the tools over a shell, and restates the approval rules.
