# Quickstart: buying via the CLI (5 minutes)

```bash
gem install portage-cli
```

```bash
# Search the web for stores that sell it — zero setup, DuckDuckGo's Instant
# Answer API is the keyless default (brand/entity queries only, e.g. "burton
# snowboards"). For open-ended queries, set BRAVE_SEARCH_API_KEY (Brave Search)
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
own docs page lists what it reads). Full walkthrough, incl. seeding a store allowlist and
what to do when the free search backend comes back empty:
[CLI usage tutorial](../cli-usage-tutorial.md).

**Pointing an agent at it:** drop the [`shop-via-ucp`](../skills/shop-via-ucp.md)
skill into your agent's skills directory instead of hand-rolling prompts — it prefers
`portage-ucp-client`/`portage` over raw MCP calls when available, and encodes the
guardrails that matter when neither is. [`serve-via-ucp`](../skills/serve-via-ucp.md)
is the merchant-side counterpart, for *setting up* a store's own UCP endpoint instead.

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

Full reference, flags, and env vars: [CLI reference](../cli-reference.md).

## Installing as a library instead

Building this into an existing Ruby app rather than shelling out to the CLI? See
[Library usage](../library-usage.md) for the `Adapter`/`Portage::Ucp.configure`/MCP-server
wiring, and [Security hooks](../security-hooks.md) before pointing it at anything real.
