# Quickstart: buying via the CLI (5 minutes)

```bash
brew install tomtom87/portage/portage   # macOS and Linux Homebrew: bundles every adapter
gem install portage-cli                 # or: any Ruby >= 3.2, add only the adapters you want
```

Upgrade with `brew upgrade portage` or `gem update portage-cli`; `~/.portage` is
never touched. If both are installed, whichever `portage` comes first on `PATH`
wins, and `portage doctor` warns when that's not the one you meant (`which -a
portage` to check). On Linux, stored payment tokens and proxy passwords need
`secret-tool` from your distro (e.g. `libsecret-tools`). Details: [installation](../cli-reference.md#installation).

Set your shipping address before buying. `portage` loads `~/.portage/.env` on startup
(`.env.example` in the repo root lists every variable it reads). Then check your setup.

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

!!! warning "Only `~/.portage/.env` loads automatically"
    A `.env` in the current directory is never loaded. A cloned repo's `.env` could
    otherwise route your traffic through its proxy or point purchases at another
    store without you noticing. Use a project file on purpose with
    `PORTAGE_ENV_FILE=.env`. [Why](../cli-reference.md#why-env-is-never-loaded-automatically).

```bash
# Search the web for stores that sell it — zero setup, DuckDuckGo's Instant
# Answer API is the keyless default (brand/entity queries only, e.g. "burton
# snowboards"). For open-ended queries, set BRAVE_SEARCH_API_KEY (Brave Search)
# or GOOGLE_CSE_KEY + GOOGLE_CSE_CX (Google Programmable Search).
portage find --query "burton snowboards" --json

# No URL: lists candidate offers, and (in a terminal) lets you pick one to
# price out with --dry-run — no charge either way. --query is optional here:
# a bare arg that doesn't look like a URL/domain is read as the query.
portage buy "burton snowboards" --max-price 600 --dry-run --json

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

## Usage

Every `portage` subcommand; the [CLI reference](../cli-reference.md) has each one's flags
and env vars.

{% include-markdown "../../portage-cli/README.md" start="<!-- usage-start -->" end="<!-- usage-end -->" %}

`buy`, `find`, `compare`, `doctor` and `payment enroll` also take `--proxy*` flags
(see [Running behind a proxy](../proxy.md)).

## Installing as a library instead

Building this into an existing Ruby app rather than shelling out to the CLI? See
[Library usage](../library-usage.md) for the `Adapter`/`Portage::Ucp.configure`/MCP-server
wiring, and [Security hooks](../security-hooks.md) before pointing it at anything real.
