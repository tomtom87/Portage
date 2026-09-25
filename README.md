# Portage::Ucp

[![gem version](https://img.shields.io/gem/v/portage-ucp)](https://rubygems.org/gems/portage-ucp)
![ruby](https://img.shields.io/badge/ruby-%3E%3D%203.2-red)
![license](https://img.shields.io/badge/license-MIT-blue)
[![docs](https://img.shields.io/badge/docs-readthedocs-blue)](https://portage.readthedocs.io/en/latest/)

**Docs**: [portage.readthedocs.io](https://portage.readthedocs.io/en/latest/)

Ruby gems that expose a commerce backend to AI shopping agents over **MCP** ([Model Context Protocol](https://modelcontextprotocol.io)) and **UCP** ([Universal Commerce Protocol](https://ucp.dev)) at once. Open-source, for any Ruby app on any e-commerce stack, agnostic, versatile and fully customizable for any business logic.

"Portage": a conduit for cargo overland between waterways a ship can't sail directly between.

> **Status**: `0.10.0`. APIs may still shift before `1.0` — see the [design log](docs/design-log.md).

## Quickstart: buying via the CLI (5 minutes)

```bash
brew install tomtom87/portage/portage   # macOS and Linux Homebrew: bundles every adapter
gem install portage-cli                 # or: any Ruby >= 3.2, add only the adapters you want
```

Upgrade with `brew upgrade portage` or `gem update portage-cli`; `~/.portage` is
never touched. If both are installed, whichever `portage` comes first on `PATH`
wins, and `portage doctor` warns when that's not the one you meant (`which -a
portage` to check). On Linux, stored payment tokens and proxy passwords need
`secret-tool` from your distro (e.g. `libsecret-tools`). Details: [installation](portage-cli/README.md#installation).

Set your shipping address before buying. `portage` loads `~/.portage/.env` on startup
([`.env.example`](.env.example) lists every variable it reads). Then check your setup.

`~/.portage/.env`:

```bash
PORTAGE_SHIP_STREET="1 Main St"
PORTAGE_SHIP_CITY="Erie"
PORTAGE_SHIP_COUNTRY="US"
PORTAGE_SHIP_POSTAL_CODE="16501"
```

```bash
chmod 600 ~/.portage/.env
portage doctor
```

> **Only `~/.portage/.env` loads automatically, never a `.env` in the current
> directory.** A cloned repo's `.env` could otherwise route your traffic through
> its proxy or point purchases at another store without you noticing. Use a
> project file on purpose with `PORTAGE_ENV_FILE=.env`. [Why](portage-cli/README.md#why-env-is-never-loaded-automatically).

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

## Usage

Every `portage` subcommand (flags and env vars for each: [`portage-cli/README.md`](portage-cli/README.md),
also published as the [CLI reference](https://portage.readthedocs.io/en/latest/cli-reference/)):

```bash
portage buy <url> --query "..." [--qty N] [--payment-token TOKEN] [--product-id ID]
                                [--yes] [--dry-run] [--auto-open|--no-auto-open]
                                [--notify-webhook URL] [--decision-backend jev|laya]
                                [--min-confidence N] [--json]
                                [--wait [--wait-timeout DURATION|off]]
portage buy --query "..." [--store URL] [--max-price N] [--limit N] ...
portage find --query "..." [--max-price N] [--limit N] [--json]
portage compare <url> --product-id ID [--id VALUE ...] [--results N]
                       [--max-price N] [--json]
portage history [list] [--purchases|--searches] [--limit N] [--json]
portage history clear [--purchases|--searches]
portage payment list [--json]
portage payment enroll <url> [--label NAME] [--json]
                              [--scope-merchant HOST ...] [--scope-max-amount N] [--scope-currency CUR]
portage payment set-default <id>
portage payment remove <id>
portage payment freeze <id>
portage payment revoke <id>
portage policy show [--json]
portage policy set [--per-transaction-cap N --currency CUR]
                    [--rolling-cap N --rolling-window-seconds N --currency CUR]
                    [--velocity-count N --velocity-window-seconds N]
                    [--allow HOST ...] [--clear-allowlist]
portage orders reconcile [--checkout ID] [--json]
portage doctor [--require FILE] [--adapter CLASS_NAME] [--json]   # aliases: configure, setup
portage generate adapter NAME [--dir DIR]
portage generate agent-profile [--out FILE] [--key-out FILE] [--rotate]
portage --version
```

`buy`, `find`, `compare`, `doctor` and `payment enroll` also take `--proxy*` flags
(see [Running behind a proxy](#running-behind-a-proxy)).

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
| [`portage-ucp`](portage-ucp/) | 0.10.0 | Protocol-only core: `Adapter` contract, capability registry, manifest builder, MCP server wrapper. |
| [`portage-ucp-client`](portage-ucp-client/) | 0.6.3 | Client SDK — connect to somebody else's manifest, or drive your own `Adapter`, as the shopper's agent. Loopback/stdio/HTTP behind one interface. |
| [`portage-ucp-webmcp`](portage-ucp-webmcp/) | 0.1.1 | WebMCP transport onto the same `Adapter` contract — inbound (`document.modelContext`) and outbound (drives a page's WebMCP tools via a browser driver). |
| [`portage-ucp-decision`](portage-ucp-decision/) | 0.1.1 | System One decision layer — offer ranking, escalation policy, a confidence gate (Jev/Laya), typed `PolicyGuard` wrapper. |
| [`portage-ucp-journal`](portage-ucp-journal/) | 0.1.1 | Buyer-side purchase journal + the injectable `Store` abstraction it's built on. |
| [`portage-cli`](portage-cli/) | 0.7.4 | Ships the `portage` command — `buy`, `find`, `compare`, `history`, `payment`, `policy`, `doctor`, `generate`. |
| [`portage-ucp-shopify`](portage-ucp-shopify/) | 0.5.1 | Shopify — Admin + Storefront GraphQL APIs. |
| [`portage-ucp-wix`](portage-ucp-wix/) | 0.1.4 | Wix — Stores Catalog and eCommerce REST APIs. |
| [`portage-ucp-woocommerce`](portage-ucp-woocommerce/) | 0.2.1 | WooCommerce — Admin REST API and Store API. |
| [`portage-ucp-bigcommerce`](portage-ucp-bigcommerce/) | 0.1.4 | BigCommerce — v3 Catalog/Carts/Checkouts and v2 Orders APIs. |
| [`portage-ucp-magento`](portage-ucp-magento/) | 0.1.4 | Magento/Adobe Commerce — REST v1 (admin-token catalog/order, guest-cart cart/checkout). |
| [`portage-ucp-etsy`](portage-ucp-etsy/) | 0.1.4 | Etsy — real catalog/order via Open API v3; checkout is redirect-link only (Etsy's public API has no cart/checkout endpoint). |
| [`portage-ucp-instagram`](portage-ucp-instagram/) | 0.1.5 | Instagram/Facebook Shops — real catalog via Meta's Graph API Commerce Catalog; checkout is redirect-link only. `get_order` is deprecated (Meta removes Order Management endpoints 2026-10-27; after that, catalog search/product + checkout handoff only). |

A backend on some other stack writes its own thin `Adapter` subclass against `portage-ucp`
directly. Every adapter gem ships the same `exe/` executable, `examples/portage_ucp.rb`
starting point, and `PORTAGE_UCP_CONFIG` config hook — see [`docs/library-usage.md`](docs/library-usage.md).
Etsy and Instagram/Facebook Shops have no real cart/checkout API to back, so those two only
implement catalog/order for real — full per-capability breakdown in
[`docs/capability-coverage.md`](docs/capability-coverage.md). Already on Shopify? Its native
Universal Commerce Agent app covers checkout+order with no code — this gem is for the
`cart`/`catalog` capabilities it doesn't advertise, a signed manifest, and every other
backend ([`docs/well-known-ucp.md`](docs/well-known-ucp.md)).

## Running behind a proxy

Portage-specific proxy config (`--proxy*` flags, `PORTAGE_PROXY*` env vars,
`~/.portage/config.json`'s `"proxy"` section, and a fail-closed inbound-trust seam
for a reverse proxy in front of the MCP/WebMCP endpoints) is implemented —
[`docs/plans/proxy-support.md`](docs/plans/proxy-support.md) tracks the full design
across its phases, and [`docs/proxy.md`](docs/proxy.md) walks through corporate
egress, a rotating residential pool, an API gateway, mitmproxy for debugging, and
nginx/Cloudflare in front of Portage's own endpoints. The CLI flags/env vars
themselves are documented in [`portage-cli/README.md`](portage-cli/README.md#proxy).

Below that Portage-specific layer, Ruby's own standard `http_proxy` env var is
still the fallback for any route nothing above configures, with caveats worth
knowing before you rely on it alone:

- **`https_proxy`/`HTTPS_PROXY` is honored correctly as of Phase 1.** Every call
  site in `portage-ucp`, `portage-cli`, and the adapter gems (`Support::HttpClient`,
  `Check`, `Support::TokenExchange`, `buy`/`find`/`payment`'s homepage probes,
  `search_backends`, `notifier`, the Shopify and Instagram adapters) now goes
  through `Support::Connection`, which resolves `https_proxy`/`HTTPS_PROXY` for an
  `https://` target and `http_proxy`/`HTTP_PROXY` for an `http://` one — unlike
  Ruby stdlib's own `Net::HTTP.start(..., p_addr: :ENV)` default, which hardcodes
  an `http_proxy`-only lookup for *any* target scheme (the bug Phase 0 confirmed;
  see the design log for the full write-up). This env fallback only applies to a
  route nothing else (a flag, `PORTAGE_PROXY*`, or config.json) has configured at
  all — see "Portage-specific proxy config" above.
- **One exception remains: `Client.fetch_manifest`** (`portage-ucp-client`), the
  manifest GET `Client.discover` makes before it ever opens an MCP session, is
  still a bare `Net::HTTP.get_response` and so still follows the old
  `http_proxy`-only rule. `Client.discover`'s own tool calls, once connected, go
  through Faraday (via the `mcp` gem's HTTP transport) and resolve the proxy from
  the *target's own scheme* independently — so a single `discover` call can have
  its manifest fetch and its tool calls pick up *different* proxies. See
  `docs/proxy.md`'s "Known gaps" section.
- **Credentials in the proxy URL work.** `http://user:pass@proxy.internal:3128` reaches
  the proxy as `Proxy-Authorization: Basic …`, for both Net::HTTP and Faraday.
- **`no_proxy`/`NO_PROXY` matching** is suffix-based: a bare `no_proxy=example.com` bypasses
  both `example.com` and any subdomain of it; a leading-dot entry (`.example.com`) bypasses
  subdomains only, not the bare domain; `host:port` entries only bypass that exact port; CIDR
  entries (`10.0.0.0/8`) match if the target hostname resolves. **`NO_PROXY=*` is not
  honored as "bypass everything"** the way curl/npm treat it — Ruby's stdlib has no special
  case for a bare `*`. Lowercase and uppercase variables are both read; if both are set,
  lowercase wins.
- `portage doctor` reports the effective proxy it detected (credentials redacted).

```bash
http_proxy=http://user:pass@proxy.internal:3128 no_proxy=localhost,127.0.0.1 \
  portage buy --query "hoodie" --dry-run --json
```

See [`docs/cli-usage-tutorial.md`](docs/cli-usage-tutorial.md) for the same example in
context, and the design log for the full Phase 0 write-up.

## Requirements

Ruby >= 3.2, and the `mcp` gem `~> 0.24` (pulled in by `portage-ucp`). The Homebrew
formula brings its own Ruby, so a brew install of the CLI needs neither. Each adapter gem
needs its backend's own credentials, read from env by its executable — see that gem's own
README, or [`docs/adapter-requirements.md`](docs/adapter-requirements.md) for the full table.

## Contributing

Bug reports and pull requests welcome at [tomtom87/Portage](https://github.com/tomtom87/Portage).
Since this is pre-`1.0` and still spec-tracking, open an issue to discuss any change bigger
than a bugfix before sending a PR. [`CONTRIBUTING.md`](CONTRIBUTING.md) has the full
workflow; participation is governed by the [Code of Conduct](CODE_OF_CONDUCT.md).

## License

[MIT](LICENSE) — Copyright (c) 2026 Tom Whitbread.
