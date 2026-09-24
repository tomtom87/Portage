# Portage::Ucp

[![gem version](https://img.shields.io/gem/v/portage-ucp)](https://rubygems.org/gems/portage-ucp)
![ruby](https://img.shields.io/badge/ruby-%3E%3D%203.2-red)
![license](https://img.shields.io/badge/license-MIT-blue)

Ruby gems that expose a commerce backend to AI shopping agents over **MCP** ([Model Context Protocol](https://modelcontextprotocol.io)) and **UCP** ([Universal Commerce Protocol](https://ucp.dev)) at once. Open-source, for any Ruby app on any e-commerce stack, agnostic, versatile and fully customizable for any business logic.

"Portage": a conduit for cargo overland between waterways a ship can't sail directly between.

> **Status**: `0.9.0`. APIs may still shift before `1.0` — see the [design log](docs/design-log.md).

## Quickstart: buying via the CLI (5 minutes)

```bash
gem install portage-cli
```

```bash
# Search the web for stores that sell it — zero setup, DuckDuckGo's Instant
# Answer API is the keyless default (brand/entity queries only, e.g. "burton
# snowboard"). For open-ended queries, set BRAVE_SEARCH_API_KEY (Brave Search)
# or GOOGLE_CSE_KEY + GOOGLE_CSE_CX (Google Programmable Search).
portage find --query "burton snowboards" --json

# No URL: lists candidate offers, and (in a terminal) lets you pick one to
# price out with --dry-run — no charge either way.
portage buy --query "burton snowboards" --max-price 600 --dry-run --json

# Have a URL? Skip search — goes straight to its /.well-known/ucp manifest.
portage buy https://some-ucp-store.example --query "hoodie" --yes --payment-token "$TOKEN"
```

`buy` tries native UCP discovery first (any store serving a real `/.well-known/ucp`
manifest), then falls back to a platform adapter only when this process already has
that platform's own credentials (`SHOPIFY_ADMIN_ACCESS_TOKEN`, etc — each adapter gem's
own README lists what it reads). Full walkthrough, incl. seeding a store allowlist and
what to do when the free search backend comes back empty:
[`docs/cli-usage-tutorial.md`](docs/cli-usage-tutorial.md).

**Pointing an agent at it:** drop the [`skills/shop-via-ucp`](skills/shop-via-ucp/SKILL.md)
skill into your agent's skills directory instead of hand-rolling prompts — it prefers
`portage-ucp-client`/`portage` over raw MCP calls when available, and encodes the
guardrails that matter when neither is. [`skills/serve-via-ucp`](skills/serve-via-ucp/SKILL.md)
is the merchant-side counterpart, for *setting up* a store's own UCP endpoint instead.

## Which doc do I want?

**Shoppers & agent builders** (automating purchases): [cli-usage-tutorial](docs/cli-usage-tutorial.md)
· [walkthrough](docs/walkthrough.md) · [shop-via-ucp skill](skills/shop-via-ucp/SKILL.md) ·
[agent-profile](docs/agent-profile.md) · [tool-gating troubleshooting](docs/ucp-tool-gating-investigation.md)

**Merchants** (serving your own UCP endpoint): [well-known-ucp](docs/well-known-ucp.md) ·
[walkthrough § serving the manifest](docs/walkthrough.md#serving-the-discovery-manifest-and-webhooks)
· [security-hooks](docs/security-hooks.md) · [serve-via-ucp skill](skills/serve-via-ucp/SKILL.md)

**Adapter authors & contributors:** [architecture](docs/architecture.md) ·
[writing-adapters](docs/writing-adapters.md) · [capability-coverage](docs/capability-coverage.md) ·
[spec-conformance](docs/spec-conformance.md) · [development](docs/development.md) ·
[`CONTRIBUTING.md`](CONTRIBUTING.md)

## The gems

Thirteen gems, mirroring how Faraday/Devise split core-vs-adapter:

| Gem | Version | Role |
|---|---|---|
| [`portage-ucp`](portage-ucp/) | 0.9.0 | Protocol-only core: `Adapter` contract, capability registry, manifest builder, MCP server wrapper. |
| [`portage-ucp-client`](portage-ucp-client/) | 0.6.2 | Client SDK — connect to somebody else's manifest, or drive your own `Adapter`, as the shopper's agent. Loopback/stdio/HTTP behind one interface. |
| [`portage-ucp-webmcp`](portage-ucp-webmcp/) | 0.1.0 | WebMCP transport onto the same `Adapter` contract — inbound (`document.modelContext`) and outbound (drives a page's WebMCP tools via a browser driver). |
| [`portage-ucp-decision`](portage-ucp-decision/) | 0.1.0 | System One decision layer — offer ranking, escalation policy, a confidence gate (Jev/Laya), typed `PolicyGuard` wrapper. |
| [`portage-ucp-journal`](portage-ucp-journal/) | 0.1.1 | Buyer-side purchase journal + the injectable `Store` abstraction it's built on. |
| [`portage-cli`](portage-cli/) | 0.7.0 | Ships the `portage` command — `buy`, `find`, `compare`, `history`, `payment`, `policy`, `doctor`, `generate`. |
| [`portage-ucp-shopify`](portage-ucp-shopify/) | 0.5.0 | Shopify — Admin + Storefront GraphQL APIs. |
| [`portage-ucp-wix`](portage-ucp-wix/) | 0.1.4 | Wix — Stores Catalog and eCommerce REST APIs. |
| [`portage-ucp-woocommerce`](portage-ucp-woocommerce/) | 0.2.1 | WooCommerce — Admin REST API and Store API. |
| [`portage-ucp-bigcommerce`](portage-ucp-bigcommerce/) | 0.1.4 | BigCommerce — v3 Catalog/Carts/Checkouts and v2 Orders APIs. |
| [`portage-ucp-magento`](portage-ucp-magento/) | 0.1.4 | Magento/Adobe Commerce — REST v1 (admin-token catalog/order, guest-cart cart/checkout). |
| [`portage-ucp-etsy`](portage-ucp-etsy/) | 0.1.4 | Etsy — real catalog/order via Open API v3; checkout is redirect-link only (Etsy's public API has no cart/checkout endpoint). |
| [`portage-ucp-instagram`](portage-ucp-instagram/) | 0.1.4 | Instagram/Facebook Shops — real catalog via Meta's Graph API Commerce Catalog; checkout is redirect-link only. `get_order` is deprecated (Meta removes Order Management endpoints 2026-10-27; after that, catalog search/product + checkout handoff only). |

A backend on some other stack writes its own thin `Adapter` subclass against `portage-ucp`
directly. Every adapter gem ships the same `exe/` executable, `examples/portage_ucp.rb`
starting point, and `PORTAGE_UCP_CONFIG` config hook — see [`docs/library-usage.md`](docs/library-usage.md).
Etsy and Instagram/Facebook Shops have no real cart/checkout API to back, so those two only
implement catalog/order for real — full per-capability breakdown in
[`docs/capability-coverage.md`](docs/capability-coverage.md). Already on Shopify? Its native
Universal Commerce Agent app covers checkout+order with no code — this gem is for the
`cart`/`catalog` capabilities it doesn't advertise, a signed manifest, and every other
backend ([`docs/well-known-ucp.md`](docs/well-known-ucp.md)).

## Other CLI commands

`portage-cli` covers more than buying:

```bash
portage compare <url> --product-id ID [--id VALUE ...] [--results N]  # where else is this sold?
portage history [list|clear] [--purchases|--searches]                 # past searches/purchases
portage payment list|enroll|set-default|remove|freeze|revoke          # stored payment tokens
portage policy show|set                                               # spend caps, velocity, allowlist
portage doctor                    # aliases: configure, setup
portage generate adapter NAME | agent-profile
```

Full reference, flags, and env vars: [`portage-cli/README.md`](portage-cli/README.md).

## Requirements

Ruby >= 3.2, and the `mcp` gem `~> 0.24` (pulled in by `portage-ucp`). Each adapter gem
needs its backend's own credentials, read from env by its executable — see that gem's own
README, or [`docs/adapter-requirements.md`](docs/adapter-requirements.md) for the full table.

## Contributing

Bug reports and pull requests welcome at [tomtom87/Portage](https://github.com/tomtom87/Portage).
Since this is pre-`1.0` and still spec-tracking, open an issue to discuss any change bigger
than a bugfix before sending a PR. [`CONTRIBUTING.md`](CONTRIBUTING.md) has the full
workflow; participation is governed by the [Code of Conduct](CODE_OF_CONDUCT.md).

## License

[MIT](LICENSE) — Copyright (c) 2026 Tom Whitbread.
