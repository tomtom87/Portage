# Skill: buy (plugin)

The full agent-facing interface to `portage`: find, compare and buy from real online
stores through the `portage` CLI. It covers what [`shop-via-ucp`](shop-via-ucp.md)
doesn't: search with no store in hand, a local store index seeded from your own
bookmarks and history or the repo's published known-stores list, the `portage setup`
wizard, hand-off to your own browser or a dedicated Portage browser profile, and
hand-off-only retailers (Amazon and others) whose terms restrict automated purchasing
agents. It ships as a [Claude Code plugin](https://docs.claude.com/en/docs/claude-code/plugins)
from this repo's own marketplace (`.claude-plugin/marketplace.json`).

## Install

{% include-markdown "../../README.md" start="<!-- buy-plugin-install-start -->" end="<!-- buy-plugin-install-end -->" %}

## Other agents

{% include-markdown "../../README.md" start="<!-- other-agents-start -->" end="<!-- other-agents-end -->" %}

## The skill

The text below is the skill itself, as the agent reads it. Its `references/` links go to the
[outcomes](references/outcomes.md), [hand-off-only retailers](references/handoff-only.md) and
[raw UCP fallback](references/raw-ucp.md) pages, which include those files as they ship.

{% include-markdown "../../plugins/buy/skills/buy/SKILL.md" start="\n---\n\n" heading-offset=2 rewrite-relative-urls=false %}
