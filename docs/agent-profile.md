# Hosting `PORTAGE_AGENT_PROFILE`

Real UCP servers (confirmed live against Shopify's 2026-08-25 rollout)
require every catalog/cart/checkout call to carry a `meta.ucp-agent.profile`
URL, and fetch it themselves before answering. An unreachable or malformed
profile fails closed — `profile_unreachable` / `profile_malformed`, both
before the call's own shape is even considered (see
`portage-ucp-client/lib/portage/ucp/client/transports/http.rb`). This is a
document describing *this agent*, distinct from `/.well-known/ucp` (see
[well-known-ucp.md](well-known-ucp.md)), which describes a *business*.

## Generating one

```sh
cd portage-cli
bundle exec exe/portage generate agent-profile \
  --out ../portage-cli/agent-profile/agent-profile.json \
  --key-out ../portage-cli/agent-profile/agent-profile.key.pem
```

Commit the `--out` JSON. Never commit `--key-out` — it's covered by the
root `.gitignore`'s `*.key.pem` pattern. Nothing in this repo signs outbound
requests with that key yet (`Portage::Ucp::Security::Signature` only
*verifies* inbound ones); it's published now so `signing_keys` isn't empty
and so a future signer has a `kid` to sign under without reshaping the
document again.

## Rotating

```sh
bundle exec exe/portage generate agent-profile --rotate \
  --out ../portage-cli/agent-profile/agent-profile.json \
  --key-out ../portage-cli/agent-profile/agent-profile.key.pem
```

`--rotate` keeps every `kid` already published and adds one more, so a
request signed under the outgoing key keeps verifying while callers move to
the new one. Nothing here ever drops a key — retire an old entry by hand
once nothing signs with it any more.

## Hosting requirements

Whatever serves this document, live UCP servers reject anything that
doesn't satisfy every one of these (from the 2026-04-08 spec):

- HTTPS, reachable with no prior coordination
- **No 3xx redirects** on the exact URL — not even http→https or a
  trailing-slash bounce
- `Cache-Control: public, max-age=<60 or more`; never `private`,
  `no-store`, or `no-cache`
- `application/json`

## This repo's default: GitHub Pages

`.github/workflows/publish-agent-profile.yml` redeploys
`portage-cli/agent-profile/agent-profile.json` on every push to `main` that
touches it, to both the Pages site root and the spec's conventional
`/.well-known/ucp-agent` path. GitHub Pages satisfies every requirement
above without extra config (HTTPS, no redirect on an exact asset path,
`Cache-Control: public, max-age=600`).

That workflow needs Actions enabled on the repo (billing/minutes) to ever
run, and as of 2026-09-17 its last three runs have failed anyway (Pages
`Source` is set to "GitHub Actions" but nothing has ever deployed to it —
`https://tomtom87.github.io/Portage/...` still 404s). Until both of those are
sorted, `.env.example`'s `PORTAGE_AGENT_PROFILE` points at jsdelivr's GitHub
CDN mirror instead:

```
https://cdn.jsdelivr.net/gh/tomtom87/Portage@main/portage-cli/agent-profile/agent-profile.json
```

Same checked-in JSON, no Pages build required. **Do not point this at
`raw.githubusercontent.com`** — confirmed live against billabong.com's real
Shopify UCP store (2026-09-17): raw.githubusercontent.com serves this exact
path as `Content-Type: text/plain; charset=utf-8`, which a strict UCP server
rejects (`profile_malformed`, surfaced by `portage-ucp-client` as a generic
"tools/call request is unprocessable" 422 with an empty body — there's no
in-band signal pointing at content-type, so check the profile URL's headers
by hand with `curl -I` if you see that error). jsdelivr serves the same file
as `application/json` with no redirect and `Cache-Control: public,
max-age=604800`, and was confirmed live past the agent-profile check on the
same store. Switch to the Pages URL once that workflow actually deploys
something — GitHub's CDN caching on raw/jsdelivr file serving isn't a
documented guarantee the way Pages is.

**One-time setup this workflow can't do for you:** Settings → Pages → Build
and deployment → Source = "GitHub Actions", on this repo. Until that's
flipped, the workflow runs and uploads an artifact with nothing to deploy
it to.

Once enabled, set:

```sh
# .env
PORTAGE_AGENT_PROFILE=https://tomtom87.github.io/Portage/agent-profile.json
```

Any other host that meets the requirements above works too — GitHub Pages
is just what this repo happens to run without asking anyone to stand up
separate infrastructure.

## Resolved: `Tool not found` on every call once the profile is wired up

**The profile was the cause after all**, contrary to what this section said
between 2026-09-17 and 2026-09-22. It is not a platform allowlist. The
capability identifiers the profile declared were wrong, and a UCP server
resolves an agent's tool registry from exactly those.

Catalog is registered per action — `dev.ucp.shopping.catalog.search` and
`dev.ucp.shopping.catalog.lookup` — not as one coarse
`dev.ucp.shopping.catalog`. `AgentProfile` declared the coarse name (it
reused `Portage::Ucp::Capabilities::CATALOG.name`, which is correct for
*our own server's* manifest, where one Capability object owns all three
catalog actions). A profile declaring only the coarse name resolves to zero
catalog tools, and the server answers `search_catalog` with `-32602 Tool not
found: search_catalog` — seconds after `tools/list` advertised it, with
nothing in the error pointing at the profile. Versions were `"1"` where the
registry uses spec revisions, and `services` was left `{}`, which declares
an agent that speaks no service at all.

Verified live 2026-09-22 against `catalog.shopify.com/api/ucp/mcp` and two
per-shop endpoints, anonymously — no Dev Dashboard token, no signatures, no
approval of any kind:

- profile declaring `dev.ucp.shopping.catalog.search`/`.lookup` →
  `search_catalog` returns real products
- profile declaring coarse `dev.ucp.shopping.catalog` → `Tool not found:
  search_catalog`, same endpoint, same connection
- no profile → `invalid_profile_url`; unreachable profile →
  `profile_unreachable`

The `get_order` tell that this section previously read as proof of an
allowlist is something narrower: Orders genuinely does require a Dev
Dashboard token carrying `read_global_api_orders`, so it is forbidden at the
anonymous tier no matter what the profile says. Catalog, Cart and Checkout
build/edit tools are all available at that tier per
[Shopify's own auth tiers](https://shopify.dev/docs/agents/profiles/auth-and-rate-limiting).
Reading one capability's real permission error as the explanation for
another capability's registry miss is what sent the whole investigation down
the allowlist path.

The one thing that *is* gated case-by-case is `complete_checkout`, which
needs both checkout permission on a token and the merchant having your
agent's channel enabled. `continue_url` — a link the shopper finishes in the
store's own checkout — is the supported path without it, and every cart and
checkout response carries one.

**What this means:** the fix was in this client. See
[`ucp-tool-gating-investigation.md`](ucp-tool-gating-investigation.md) for
the full trail, including the localization-context bug found underneath this
one.
