# Skill: browse-via-ucp

The read-only counterpart to [`shop-via-ucp`](shop-via-ucp.md). Drop it into an agent's
skills directory to look around a store's UCP/MCP commerce backend for a shopper: read its
manifest, search its catalog, read product details and prices, and say whether the store
supports automated buying. It never creates, updates or completes a cart or checkout, and
hands over to `shop-via-ucp` when the shopper wants to buy.

{% include-markdown "../../skills/browse-via-ucp/SKILL.md" start="\n---\n\n" %}
