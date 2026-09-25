# CLI usage tutorial: install, search, dry-run buy

A walkthrough of `portage-cli` from a clean machine — install, search-only
`find`, dry-run `buy`, and what to do when the free search backend comes back
empty.

## Install

With Homebrew (macOS or Linux), which installs the CLI and every adapter gem
on Homebrew's own Ruby:

```bash
brew install tomtom87/portage/portage
```

Or with RubyGems, on any Ruby ≥ 3.2, adding only the adapters you want:

```bash
gem install portage-cli
```

The gem pulls in `portage-ucp`, `portage-ucp-client`, and `portage-ucp-journal`
as dependencies. Upgrade later with `brew upgrade portage` or
`gem update portage-cli`; neither touches `~/.portage`. If you have both,
whichever `portage` comes first on `PATH` wins; `which -a portage` shows which,
and `portage doctor` warns when a copy you didn't mean to run is shadowing the
other. On Linux, stored payment tokens need `secret-tool` from your distro
(e.g. `libsecret-tools`). See the [CLI reference](cli-reference.md#installation)
for details.

Then set your shipping address (the country at least: without it some stores
report in-stock items as out of stock) in `~/.portage/.env`, which `portage`
loads on startup, and check your setup.

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
    `PORTAGE_ENV_FILE=.env`. [Why](cli-reference.md#why-env-is-never-loaded-automatically).

`doctor` reports how Portage was installed, the Ruby it runs on and which
adapters load, then lists anything to fix.

## Search only — no charge

```bash
portage find --query "usb-c cable" --max-price 20 --json
```

`find` never touches payment or checkout — it only resolves candidate stores
and probes their `/.well-known/ucp` manifest. Safe to run freely.

## Resolve price/path without completing checkout

```bash
portage buy --query "usb-c cable" --max-price 20 --dry-run --json
```

Same search-and-probe pipeline as `find`, but shaped like a real `buy` call
so you can see the price/path resolution `buy` would use — `--dry-run` stops
before checkout, no charge either way.

```bash
portage buy https://some-ucp-store.example --query "hoodie" --dry-run
```

Point `buy` at a known store URL directly and it skips search entirely,
going straight to manifest probe. Against a domain with no UCP manifest (or
that doesn't resolve), it fails clean:

```
No automated path — visit https://some-ucp-store.example yourself. (source: none)
```

## Why generic queries return nothing

`find`/`buy --query` resolve candidate stores through search backends
(`portage-cli/lib/portage/cli/search_backends.rb`), tried in this order:

1. **Allowlist** — `~/.portage/stores.yml` or `PORTAGE_STORES` env var. No
   key, no network call, query-independent (always considered).
2. **DuckDuckGo** Instant Answer API — no key, always `available?`, so it's
   the default when nothing else is configured.
3. **Brave Search** — needs `BRAVE_SEARCH_API_KEY`.
4. **Google Programmable Search** — needs `GOOGLE_CSE_KEY` + `GOOGLE_CSE_CX`.

With no keys and no allowlist file, DuckDuckGo is the *only* backend that
runs. And DuckDuckGo's Instant Answer API is an **entity resolver, not a web
search** — it answers "what official site does this named thing have," not
"what stores sell this category of thing." Confirmed directly against the
API:

```bash
curl -s "https://api.duckduckgo.com/?q=usb-c+cable&format=json&no_html=1&no_redirect=1"
# => "Results": [], "RelatedTopics": []

curl -s "https://api.duckduckgo.com/?q=ugreen&format=json&no_html=1&no_redirect=1"
# => full Wikipedia company entity (founder, industry, ticker...) but still "Results": []
```

Generic category queries ("usb-c cable") and even well-known brand names
(ugreen, belkin, apple) routinely come back with an empty `Results` field —
DuckDuckGo just doesn't populate the official-site link reliably. A single
unambiguous brand query can work:

```bash
portage find --query "burton snowboards" --json
```

```json
{
  "query": "burton snowboards",
  "candidates": [{ "origin": "https://www.burton.com", "source": "duckduckgo" }],
  "stores": [],
  "offers": [],
  "message": "Checked 1 store(s); none of them speak UCP."
}
```

DuckDuckGo resolved `burton.com`, `find` probed it for a UCP manifest, found
none — a clean, correct empty result (burton.com just doesn't speak UCP),
not a search failure. This confirms the full pipeline works end to end:
search → candidate → manifest probe → graceful no-match.

## Getting real results

DuckDuckGo-only is a keyless fallback, not a real search engine. To make
`find`/`buy --query` actually useful for category queries:

- **Set `BRAVE_SEARCH_API_KEY`** — real web search, free tier available.
- **Set `GOOGLE_CSE_KEY` + `GOOGLE_CSE_CX`** — Google Programmable Search.
- **Seed `~/.portage/stores.yml`** (bare YAML array of URLs) or
  `PORTAGE_STORES` (comma-separated) — costs no network call, always
  considered regardless of query, good for stores you already trust.

All of these, and the `PORTAGE_SHIP_*` address, are listed in the repo's
`.env.example`.

## Seeding the allowlist from a directory site

`https://ucptools.dev/directory` lists ~100 stores with a self-assigned
"AI commerce readiness grade." Treat that grade as noise, not signal: the
site grades *itself* Grade A, and it's not verifiable — a grade doesn't mean
the store actually serves a UCP manifest. It has no API either, just an
HTML page.

Don't copy its list on faith. Instead, pull the raw domain list off the page
and probe each one directly for a real manifest:

```bash
while read -r d; do
  code=$(curl -s -o /tmp/resp.json -w "%{http_code}" --max-time 4 "https://$d/.well-known/ucp")
  if [ "$code" = "200" ] && grep -qi '"ucp"' /tmp/resp.json; then
    echo "$d"
  fi
done < domains.txt
```

Out of the ~99 domains listed, 38 answered with a real manifest (all on
Shopify, `"version":"2026-08-25"`) — everything from Allbirds and Glossier to
Skims and The Body Shop. The other ~60 (Instacart, Trader Joe's, Tesco,
Whole Foods, etc.) returned nothing at `/.well-known/ucp` — not UCP stores
regardless of what grade the directory gave them.

Only the verified 38 went into `~/.portage/stores.yml`. Once seeded, the
Allowlist backend picks them up automatically — no key, no network call to
resolve candidates, and (being query-independent) every `find`/`buy --query`
call considers all of them; each store's own catalog search decides whether
it stocks the thing you asked for:

```bash
portage find --query "usb-c cable" --max-price 20 --json
# => 38 candidates, source: "allowlist" — probed regardless of query,
#    each store's catalog decides fit
```

## Running behind a proxy

```bash
portage buy --query "hoodie" --dry-run --json \
  --proxy http://user:pass@proxy.internal:3128 --no-proxy localhost,127.0.0.1
```

`--proxy`/`--no-proxy` (and their `PORTAGE_PROXY`/`PORTAGE_NO_PROXY` env
equivalents, and `~/.portage/config.json`'s `"proxy"` section) are the
Portage-specific way to configure this — see [`proxy.md`](proxy.md) for corporate
egress, a rotating residential pool, an API gateway, mitmproxy for debugging, and
nginx/Cloudflare in front of the MCP/WebMCP endpoints, and
the [CLI reference](cli-reference.md#proxy) for the full flag/env
reference. Below that layer, the plain `http_proxy`/`HTTPS_PROXY`/`NO_PROXY` env
vars are still the fallback for any route left unconfigured — see the root
[`README.md`](https://github.com/tomtom87/Portage#running-behind-a-proxy) for the stdlib quirks worth
knowing there. `portage doctor` reports the effective proxy per route, credentials
redacted.

## Known issue: `Client.discover` can't parse real 2026-08-25 manifests

Testing `buy` against a handful of the verified 38 (Casper, Glossier,
Olaplex — all real, live UCP manifests) all came back
`"No automated path — visit ... yourself."` even though `curl
https://casper.com/.well-known/ucp` returns a full, valid manifest with
`checkout`/`cart`/`catalog` capabilities and a Google Pay handler.

Root cause: `Portage::Ucp::Client.fetch_manifest`
(`portage-ucp-client/lib/portage/ucp/client.rb`) expects the older flat
manifest shape — top-level `services` as an *array* of
`{transport, endpoint}` objects, top-level `capabilities` as an *array* of
`{name}` objects. The manifests these stores actually serve nest everything
one level deeper under an `"ucp"` key, with `services`/`capabilities` as
*hashes* keyed by service/capability name:

```json
{
  "ucp": {
    "version": "2026-08-25",
    "services": { "dev.ucp.shopping": [{ "transport": "mcp", "endpoint": "..." }] },
    "capabilities": { "dev.ucp.shopping.checkout": [...], "dev.ucp.shopping.cart": [...] }
  }
}
```

`Array(manifest["services"])` reads `nil` off the mismatched top level,
so `mcp_endpoint` never finds an endpoint and raises `DiscoveryError` —
silently swallowed by `Buy#discover`'s `rescue ... nil`, which is why it
looks like a normal "not a UCP store" result instead of an error. Confirmed
directly:

```bash
ruby -Ilib -e '
require "portage/ucp/client"
Portage::Ucp::Client.discover("https://casper.com")
'
# => Portage::Ucp::Client::DiscoveryError: manifest has no mcp service entry to connect to
```

This isn't a per-store problem — every store in the verified allowlist will
hit the same wall until `fetch_manifest`/`mcp_endpoint`/`capability_names`
are updated to read the `"ucp"`-nested, hash-shaped manifest that real
stores (Shopify's rollout, as of 2026-08-25) actually serve.
