# Skill: shop-research (plugin)

The read-only sibling of the [`buy`](buy.md) skill, shipped in the same `buy` plugin. It
answers product and store questions through the `portage` CLI without buying anything:
what something costs, where to get it, whether it's in stock, what Portage knows about a
store (whether it can buy there, what the store supports, the business details and policy
links it publishes, when the local index last saw it), and what you ordered through
Portage. Store details are the store's own statements, never a vouch for the store. It runs only `portage find`, `index search`,
`index show`, `check`, `pick --view`, `history` and `doctor`, and never creates a cart, a
checkout or a payment. When you ask it to buy something, it hands over to `buy`.

It installs with the `buy` plugin (see [Install](buy.md#install)). For other agents, copy
`plugins/buy/skills/shop-research/` next to `plugins/buy/skills/buy/` (see
[Other agents](buy.md#other-agents)).

## The skill

The text below is the skill itself, as the agent reads it.

{% include-markdown "../../plugins/buy/skills/shop-research/SKILL.md" start="\n---\n\n" heading-offset=2 rewrite-relative-urls=false %}
