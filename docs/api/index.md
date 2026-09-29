# API reference

Reference pages for developers. Each one is checked against the source of the version
shown. For a guided introduction, start with [library usage](../library-usage.md) or the
[agentic flow tutorial](../agentic-flow.md).

| Page | Gem | Version | Use it to… |
|---|---|---|---|
| [CLI JSON reference](cli-json.md) | `portage-cli` | 0.8.0 | Drive `portage` from an agent or script and branch on its `--json` output |
| [`portage-ucp`](portage-ucp.md) | `portage-ucp` | 0.10.0 | Serve a store over UCP and MCP: `Adapter` contract, value objects, manifest, MCP server, security hooks |
| [`portage-ucp-client`](portage-ucp-client.md) | `portage-ucp-client` | 0.6.3 | Connect to a store's manifest as the shopper's agent, or drive your own `Adapter` in-process |
| [`portage-ucp-decision`](portage-ucp-decision.md) | `portage-ucp-decision` | 0.1.1 | Rank offers, decide when to escalate to the person, and gate on confidence |
| [`portage-ucp-journal`](portage-ucp-journal.md) | `portage-ucp-journal` | 0.1.1 | Record buyer-side purchases, with your own storage backend |
| [`portage-ucp-webmcp`](portage-ucp-webmcp.md) | `portage-ucp-webmcp` | 0.2.0 | Serve tools in the page, or drive a page's WebMCP tools from a browser |

Every command, flag and environment variable of the `portage` command is in the
[CLI reference](../cli-reference.md). Platform adapters (Shopify, Wix, WooCommerce,
BigCommerce, Magento, Etsy, Instagram) implement the `portage-ucp` `Adapter` contract;
their own pages under **Adapters** list the credentials and capabilities each one supports.
