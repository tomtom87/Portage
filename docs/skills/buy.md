# Skill: buy (plugin)

The full agent-facing interface to `portage`: find, compare and buy from real online
stores through the `portage` CLI. It covers what [`shop-via-ucp`](shop-via-ucp.md)
doesn't: search with no store in hand, a local store index seeded from your own
bookmarks and history or the repo's published known-stores list, the `portage setup`
wizard, hand-off to your own browser or a dedicated Portage browser profile, and
hand-off-only retailers (Amazon and others) whose terms restrict automated purchasing
agents. It ships as a [Claude Code plugin](https://docs.claude.com/en/docs/claude-code/plugins)
from this repo's own marketplace (`.claude-plugin/marketplace.json`).

The plugin also ships [`shop-research`](shop-research.md), a read-only skill for questions
with no purchase in mind (a price, stock, a store, a past order). It never runs `buy` and
hands over to this skill when you want to buy.

## Install

{% include-markdown "../../README.md" start="<!-- buy-plugin-install-start -->" end="<!-- buy-plugin-install-end -->" %}

## Other agents

{% include-markdown "../../README.md" start="<!-- other-agents-start -->" end="<!-- other-agents-end -->" %}

## You pick the store and approve the total

The agent never chooses the store and never says yes for you. At two points it stops and asks:

1. **Pick.** After a search, the agent runs `portage pick --json` and shows you the offers, each with a link to the store's product page. You choose one (or "Compare an offer across stores"). It can open a page in your browser if you ask.
2. **Approve.** After a dry run, it shows the exact total for that offer, with the product link, and asks yes or no. A yes covers that one quote, at that total. If the price rises before it buys, `portage` refuses (`quote_changed`) and nothing is charged.

By default (`require_approval: any`) the agent relays your answer with `portage approve --relayed-yes`. For more assurance, run this once in your own terminal:

```bash
portage policy set --require-approval person
```

Then a purchase goes through only after you type yes in your own terminal (`portage approve QUOTE_ID`), and the agent asks you to do that instead of relaying. Lowering the setting also needs a yes at a terminal, so the agent can't turn it off. Details: [the approval policy](../agentic-flow.md#the-approval-policy) and the [CLI JSON reference](../api/cli-json.md#policy-set-require-approval).

!!! warning "Upgrade note"
    Under the default `any`, a `buy --yes` without an approved `--quote` no longer buys. It dry-runs and asks for approval. To keep the old behaviour, run `portage policy set --require-approval off` from a terminal.

!!! note "`person` is not a hard guarantee"
    A model can't type on your terminal, but an agent with a shell can edit `~/.portage/policy.json` or the quote files in `~/.portage/quotes/`, or open a terminal of its own with `script` or `expect`. `person` raises the bar. It doesn't replace not giving an untrusted agent a shell. Also, the "compare" choice uses your proxy settings from the environment and `config.json` (`pick` has no `--proxy` flags).

This needs `portage-cli` 0.9.0 or newer, the first release with `pick` and `approve`.

## The skill

The text below is the skill itself, as the agent reads it. Its `references/` links go to the
[outcomes](references/outcomes.md), [hand-off-only retailers](references/handoff-only.md) and
[raw UCP fallback](references/raw-ucp.md) pages, which include those files as they ship.

{% include-markdown "../../plugins/buy/skills/buy/SKILL.md" start="\n---\n\n" heading-offset=2 rewrite-relative-urls=false %}
