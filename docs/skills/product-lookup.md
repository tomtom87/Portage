# Skill: product-lookup (plugin)

The read-only sibling of the [`buy`](buy.md) skill, shipped in the same `buy` plugin. It
answers product questions through the `portage` CLI without buying anything: what
something costs, where to get it, whether it's in stock, whether Portage can buy from a
store, and what you ordered through Portage. It runs only `portage find`, `index search`,
`index show`, `check`, `pick --view`, `history` and `doctor`, and never creates a cart, a
checkout or a payment. When you ask it to buy something, it hands over to `buy`.

It installs with the `buy` plugin (see [Install](buy.md#install)). For other agents, copy
`plugins/buy/skills/product-lookup/` next to `plugins/buy/skills/buy/` (see
[Other agents](buy.md#other-agents)).

## The skill

The text below is the skill itself, as the agent reads it.

{% include-markdown "../../plugins/buy/skills/product-lookup/SKILL.md" start="\n---\n\n" heading-offset=2 rewrite-relative-urls=false %}
