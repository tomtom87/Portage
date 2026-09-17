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

## Still open: `Tool not found` on every call once the profile is wired up

`portage generate agent-profile`
(`portage-cli/lib/portage/cli/generate/agent_profile.rb`) used to write
`"ucp": { "services": {}, "capabilities": {}, "payment_handlers": {} }` —
deliberately stubbed, per that file's own comments, so a future signer had a
`kid` to sign under without reshaping the document again. Nobody had gone
back to fill `capabilities` in with what this agent actually supports.

Confirmed live against billabong.com (2026-09-17), once hosting was fixed
(profile fetch succeeds, past guardrail 1): every real tool call —
`search_catalog`, `lookup_catalog`, `get_product`, `create_cart`, all
confirmed present seconds earlier by `tools/list` — came back
`-32602 Invalid params, "Tool not found: <name>"` the moment
`meta.ucp-agent.profile` was attached to the call. Not one tool, not
catalog-specific — every tool, uniformly, only once the profile was in play.

**Tested fix, didn't work:** `AgentProfile#build_document` now populates
`capabilities` with the same shape `Portage::Ucp::Manifest#capability_hash`
uses for a business's own `/.well-known/ucp` document —
`{ "<capability-name>": [{"version": "<v>"}] }` — reusing the four
`Portage::Ucp::Capabilities::{CATALOG,CART,CHECKOUT,ORDER}` constants, since
those are exactly the four groups `Portage::Ucp::Client::Session` always
implements. Re-ran the same `search_catalog` call against billabong.com with
this populated profile (served fresh, confirmed via `curl -I` — correct
content-type, no cache hit) and got the identical `Tool not found:
search_catalog`. So an empty `capabilities` object either isn't the cause, or
isn't the whole cause. The populated version is still a strict improvement
over shipping an empty object with no way to ever be more correct, so it
stays, but don't expect it to unblock a real store on its own.

**What this doesn't rule out:** the store fetches and 200s the profile every
time (confirmed via response headers changing per test), so discovery and
hosting are not the problem. Also ruled out since the above: this isn't
specific to billabong.com being a stranger's store — the identical error
reproduces against `ucp-test-bc2vif1p.myshopify.com`, a dev store this
project owns outright with real admin credentials. Owning the store didn't
help, which points at a platform-side gate on tool *execution*, independent
of merchant config. Full writeup and suggested next steps:
[`ucp-tool-gating-investigation.md`](ucp-tool-gating-investigation.md).
