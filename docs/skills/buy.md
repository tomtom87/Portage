# Skill: buy (plugin)

The full agent-facing interface to `portage` — find, compare and buy from real online
stores through the `portage` CLI, including the parts [`shop-via-ucp`](shop-via-ucp.md)
doesn't cover: search with no store in hand, a local store index seeded from your own
bookmarks/history or the repo's published known-stores list, the `portage setup`
wizard, hand-off to your own browser or a dedicated Portage browser profile, and
hand-off-only retailers (Amazon and others) whose own terms restrict automated
purchasing agents. Distributed as a [Claude Code plugin](https://docs.claude.com/en/docs/claude-code/plugins)
from this repo's own marketplace (`.claude-plugin/marketplace.json`) — install it with
`/plugin marketplace add tomtom87/Portage` then `/plugin install buy`, or point any
other host with the plugin system at `plugins/buy`.

{% include-markdown "../../plugins/buy/skills/buy/SKILL.md" start="\n---\n\n" %}
