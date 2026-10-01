# Skill: shop-via-ucp

Drop this skill into an agent's skills directory to act as a shopper's agent against a
store's UCP/MCP commerce backend, instead of hand-rolling the tool-call sequence and its
guardrails yourself. It's for completing a purchase. For lookups with no purchase in mind
(what a store sells, a price, whether it supports automated buying), use the read-only
[`browse-via-ucp`](browse-via-ucp.md) skill.

{% include-markdown "../../skills/shop-via-ucp/SKILL.md" start="\n---\n\n" %}
