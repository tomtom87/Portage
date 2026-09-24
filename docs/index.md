# Portage

Ruby gems that expose a commerce backend to AI shopping agents over **MCP**
([Model Context Protocol](https://modelcontextprotocol.io)) and **UCP**
([Universal Commerce Protocol](https://ucp.dev)) at once. Open-source, for any Ruby app on
any e-commerce stack, agnostic, versatile and fully customizable for any business logic.

"Portage": a conduit for cargo overland between waterways a ship can't sail directly between.

!!! info "Status"
    `0.9.0`. APIs may still shift before `1.0`.

Start here: [Quickstart](getting-started/quickstart.md).

## Which doc do I want?

**Shoppers & agent builders** (automating purchases): [CLI usage tutorial](cli-usage-tutorial.md)
· [Walkthrough](walkthrough.md) · [shop-via-ucp skill](skills/shop-via-ucp.md) ·
[Agent profile](agent-profile.md) · [Tool-gating troubleshooting](ucp-tool-gating-investigation.md)

**Merchants** (serving your own UCP endpoint): [Serving /.well-known/ucp](well-known-ucp.md) ·
[Walkthrough § serving the manifest](walkthrough.md#serving-the-discovery-manifest-and-webhooks)
· [Security hooks](security-hooks.md) · [serve-via-ucp skill](skills/serve-via-ucp.md)

**Adapter authors & contributors:** [Architecture](architecture.md) ·
[Writing adapters](writing-adapters.md) · [Capability coverage](capability-coverage.md) ·
[Spec conformance](spec-conformance.md) · [Development](development.md) ·
[Contributing](contributing.md)

## The gems

Thirteen gems, mirroring how Faraday/Devise split core-vs-adapter:

| Gem | Version | Role |
|---|---|---|
| [`portage-ucp`](core-gems/portage-ucp.md) | 0.9.0 | Protocol-only core: `Adapter` contract, capability registry, manifest builder, MCP server wrapper. |
| [`portage-ucp-client`](core-gems/portage-ucp-client.md) | 0.6.2 | Client SDK — connect to somebody else's manifest, or drive your own `Adapter`, as the shopper's agent. Loopback/stdio/HTTP behind one interface. |
| [`portage-ucp-webmcp`](adapters/webmcp.md) | 0.1.0 | WebMCP transport onto the same `Adapter` contract — inbound (`document.modelContext`) and outbound (drives a page's WebMCP tools via a browser driver). |
| [`portage-ucp-decision`](core-gems/portage-ucp-decision.md) | 0.1.0 | System One decision layer — offer ranking, escalation policy, a confidence gate (Jev/Laya), typed `PolicyGuard` wrapper. |
| [`portage-ucp-journal`](core-gems/portage-ucp-journal.md) | 0.1.1 | Buyer-side purchase journal + the injectable `Store` abstraction it's built on. |
| [`portage-cli`](cli-reference.md) | 0.7.0 | Ships the `portage` command — `buy`, `find`, `compare`, `history`, `payment`, `policy`, `doctor`, `generate`. |
| [`portage-ucp-shopify`](adapters/shopify.md) | 0.5.0 | Shopify — Admin + Storefront GraphQL APIs. |
| [`portage-ucp-wix`](adapters/wix.md) | 0.1.4 | Wix — Stores Catalog and eCommerce REST APIs. |
| [`portage-ucp-woocommerce`](adapters/woocommerce.md) | 0.2.1 | WooCommerce — Admin REST API and Store API. |
| [`portage-ucp-bigcommerce`](adapters/bigcommerce.md) | 0.1.4 | BigCommerce — v3 Catalog/Carts/Checkouts and v2 Orders APIs. |
| [`portage-ucp-magento`](adapters/magento.md) | 0.1.4 | Magento/Adobe Commerce — REST v1 (admin-token catalog/order, guest-cart cart/checkout). |
| [`portage-ucp-etsy`](adapters/etsy.md) | 0.1.4 | Etsy — real catalog/order via Open API v3; checkout is redirect-link only (Etsy's public API has no cart/checkout endpoint). |
| [`portage-ucp-instagram`](adapters/instagram.md) | 0.1.4 | Instagram/Facebook Shops — real catalog via Meta's Graph API Commerce Catalog; checkout is redirect-link only. `get_order` is deprecated (Meta removes Order Management endpoints 2026-10-27; after that, catalog search/product + checkout handoff only). |

A backend on some other stack writes its own thin `Adapter` subclass against `portage-ucp`
directly. Every adapter gem ships the same `exe/` executable, `examples/portage_ucp.rb`
starting point, and `PORTAGE_UCP_CONFIG` config hook — see [Library usage](library-usage.md).
Etsy and Instagram/Facebook Shops have no real cart/checkout API to back, so those two only
implement catalog/order for real — full per-capability breakdown in
[Capability coverage](capability-coverage.md) (and the [feature matrix](adapters/feature-matrix.md)
for a row-per-adapter view). Already on Shopify? Its native
Universal Commerce Agent app covers checkout+order with no code — this gem is for the
`cart`/`catalog` capabilities it doesn't advertise, a signed manifest, and every other
backend ([Serving /.well-known/ucp](well-known-ucp.md)).

## Requirements

Ruby >= 3.2, and the `mcp` gem `~> 0.24` (pulled in by `portage-ucp`). Each adapter gem
needs its backend's own credentials, read from env by its executable — see that gem's own
docs page, or [Adapter requirements](adapter-requirements.md) for the full table.

## Contributing

Bug reports and pull requests welcome at [tomtom87/Portage](https://github.com/tomtom87/Portage).
Since this is pre-`1.0` and still spec-tracking, open an issue to discuss any change bigger
than a bugfix before sending a PR. [Contributing](contributing.md) has the full
workflow.

## License

MIT — Copyright (c) 2026 Tom Whitbread.
