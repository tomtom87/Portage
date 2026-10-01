# Portage

Portage lets an AI agent find and buy things from real online stores for you, and you
approve every payment. It ships as a command-line tool (`portage`), a Claude Code plugin
(`buy`) that drives it, and Ruby gems that let any store serve the same open protocols
([MCP](https://modelcontextprotocol.io) and [UCP](https://ucp.dev)) to shopping agents.

!!! info "Status"
    Pre-1.0. APIs may still change between minor versions. Latest release set: 0.11.0
    ([changelog](changelog.md)).

## Start here

| You want to… | Read |
|---|---|
| Buy something through Claude or another agent | [Quickstart](getting-started/quickstart.md), then the [buy plugin](skills/buy.md) |
| Build an agent that shops through Portage | [Agentic flow tutorial](agentic-flow.md), then the [CLI JSON reference](api/cli-json.md) |
| Call a store's UCP endpoint from Ruby | [Walkthrough](walkthrough.md) and the [`portage-ucp-client` API](api/portage-ucp-client.md) |
| Let agents buy from your store | [Serving `/.well-known/ucp`](well-known-ucp.md), [`portage-ucp` API](api/portage-ucp.md), [security hooks](security-hooks.md) |
| Write an adapter for a new platform | [Writing adapters](writing-adapters.md), [architecture](architecture.md), [capability coverage](capability-coverage.md) |
| Understand the protocols | [UCP overview](concepts/ucp-overview.md) |

## How it works

A shopper's agent never scrapes. It works with stores that publish a UCP manifest at
`/.well-known/ucp`, with stores whose pages expose WebMCP tools, and with platforms whose
API credentials you already hold (your own store). Everything else ends in a hand-off:
Portage builds what it can, then opens the checkout for you to pay.

| Tier | What happens | Default |
|---|---|---|
| A | Opens the checkout in your own browser. You pay. | On |
| B | A separate Portage browser profile builds the cart, then stops at payment. You pay. | Off (opt in) |
| C | Hand-off only. Portage opens the page and you buy it yourself. No requests to the site, no scraping, no automation of any kind. | Every Amazon site, plus walmart.com, ebay.com, bestbuy.com and any host you add |

Hard rules, in every tier: card data never passes through Portage; nothing is bought
without your explicit yes; Portage never reads your browser's password, cookie or
autofill stores or attaches to your default browser profile; and it never solves or
bypasses a CAPTCHA. Portage is open-source software provided as-is, without warranty of
any kind (MIT). How you use it on any site, and compliance with that site's terms, is your
responsibility. Details: [CLI reference § Tiers](cli-reference.md#tiers-how-a-purchase-actually-finishes)
and [Security](security.md).

## Packages

| Package | Version | For | What it does | Docs |
|---|---|---|---|---|
| `buy` plugin | 0.9.0 | Shoppers | Claude Code plugin that shops through `portage`, plus a read-only product-lookup skill | [buy skill](skills/buy.md), [product-lookup skill](skills/product-lookup.md) |
| `portage-cli` | 0.11.0 | Shoppers, agent builders | The `portage` command | [CLI reference](cli-reference.md), [tutorial](cli-usage-tutorial.md), [JSON reference](api/cli-json.md) |
| `shop-via-ucp` skill | – | Agent builders | Buy through a store's UCP endpoint, with or without `portage` | [skill](skills/shop-via-ucp.md) |
| `browse-via-ucp` skill | – | Agent builders | Read-only: a store's manifest, catalog and whether it supports automated buying | [skill](skills/browse-via-ucp.md) |
| `portage-ucp-client` | 0.6.3 | Agent builders | Ruby client: connect to a store's manifest, or drive your own `Adapter`, as the shopper's agent | [API](api/portage-ucp-client.md), [README](core-gems/portage-ucp-client.md) |
| `portage-ucp-decision` | 0.1.1 | Agent builders | Offer ranking, escalation policy, confidence gate (Jev/Laya), `PolicyGuard` | [API](api/portage-ucp-decision.md), [README](core-gems/portage-ucp-decision.md) |
| `portage-ucp-journal` | 0.1.1 | Agent builders | Buyer-side purchase journal and its `Store` abstraction | [API](api/portage-ucp-journal.md), [README](core-gems/portage-ucp-journal.md) |
| `portage-ucp-webmcp` | 0.2.0 | Both | WebMCP transport: serve tools in the page, or drive a page's tools (Tier B profile, autofill) | [API](api/portage-ucp-webmcp.md), [README](adapters/webmcp.md) |
| `portage-ucp` | 0.11.0 | Merchants | Protocol core: `Adapter` contract, capability registry, manifest builder, MCP server | [API](api/portage-ucp.md), [README](core-gems/portage-ucp.md) |
| `serve-via-ucp` skill | – | Merchants | Set up a store's own UCP endpoint | [skill](skills/serve-via-ucp.md) |
| `portage-ucp-shopify` | 0.5.1 | Merchants | Shopify Admin and Storefront GraphQL APIs | [README](adapters/shopify.md) |
| `portage-ucp-wix` | 0.1.5 | Merchants | Wix Stores Catalog and eCommerce REST APIs | [README](adapters/wix.md) |
| `portage-ucp-woocommerce` | 0.2.2 | Merchants | WooCommerce Admin REST API and Store API | [README](adapters/woocommerce.md) |
| `portage-ucp-bigcommerce` | 0.1.5 | Merchants | BigCommerce v3 Catalog/Carts/Checkouts and v2 Orders APIs | [README](adapters/bigcommerce.md) |
| `portage-ucp-magento` | 0.1.5 | Merchants | Magento/Adobe Commerce REST v1 | [README](adapters/magento.md) |
| `portage-ucp-etsy` | 0.1.5 | Merchants | Etsy Open API v3 catalog and orders; checkout is a redirect link | [README](adapters/etsy.md) |
| `portage-ucp-instagram` | 0.1.5 | Merchants | Meta Commerce Catalog; checkout is a redirect link; `get_order` is deprecated and stops working after Meta removes its Order Management endpoints on 2026-10-27 | [README](adapters/instagram.md) |

Every adapter gem ships an `exe/` server, an `examples/portage_ucp.rb` starting point and
the `PORTAGE_UCP_CONFIG` hook ([library usage](library-usage.md)). Credentials per
platform: [adapter requirements](adapter-requirements.md). Row-per-adapter view: the
[feature matrix](adapters/feature-matrix.md). On Shopify, the native Universal Commerce
Agent app covers checkout and orders with no code; Portage adds `cart`, `catalog` and a
signed manifest ([serving `/.well-known/ucp`](well-known-ucp.md)).

## Requirements

Ruby 3.2 or newer, and the `mcp` gem `~> 0.24` (pulled in by `portage-ucp`). The Homebrew
formula brings its own Ruby, so a Homebrew install needs neither.

## Contributing

Bug reports and pull requests are welcome at
[tomtom87/Portage](https://github.com/tomtom87/Portage). The project is pre-1.0 and still
tracking the spec, so open an issue before any change bigger than a bugfix.
[Contributing](contributing.md) has the workflow. AI agents: this site publishes
[`llms.txt` and `llms-full.txt`](ai-agents.md).

## License

MIT. Copyright (c) 2026 Tom Whitbread.
