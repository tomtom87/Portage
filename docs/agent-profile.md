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

`portage generate agent-profile`
(`portage-cli/lib/portage/cli/generate/agent_profile.rb`) used to write
`"ucp": { "services": {}, "capabilities": {}, "payment_handlers": {} }` —
deliberately stubbed, per that file's own comments, so a future signer had a
`kid` to sign under without reshaping the document again. Nobody had gone
back to fill `capabilities` in with what this agent actually supports.
That's since been fixed (`AgentProfile#build_document` now populates
`capabilities` with the same shape `Portage::Ucp::Manifest#capability_hash`
uses for a business's own `/.well-known/ucp` document), but it turned out
not to be the cause of the failure below.

Confirmed live against billabong.com and against
`ucp-test-bc2vif1p.myshopify.com` (a Shopify dev store this project owns
outright) on 2026-09-17: every real tool call — `search_catalog`,
`lookup_catalog`, `get_product`, `create_cart`, all confirmed present
seconds earlier by `tools/list` — came back `-32602 Invalid params, "Tool
not found: <name>"` the moment `meta.ucp-agent.profile` was attached to the
call. Filling in `capabilities` didn't change this, and neither did owning
the store.

**Confirmed root cause:** it's a platform-side authorization gate on tool
*invocation*, unrelated to the agent-profile document, the manifest, or the
request's wire shape — all proven correct via live testing. The tell is
`get_order`, which returns an honest `"You are forbidden to make tools/call
requests"` for the exact same session, identically whether
`meta.ucp-agent.profile` points at our real, valid profile or at a garbage
URL that resolves to nothing UCP-shaped — proving profile content is
irrelevant to the rejection. `search_catalog`/`create_cart`/etc. hit the
same gate but surface it as a misleading `"Tool not found"` instead: the
tool is silently absent from this agent's per-session tool registry, even
though `tools/list` advertises it moments earlier. Most likely explanation:
Shopify's UCP rollout authorizes tool calls against an allowlist of
approved agent partners, and this agent isn't on it yet.

**What this means:** there is no code fix available in Portage — this is an
external platform gate, not a bug in this client. What's still open is
whether Shopify publishes an allowlist/partner-registration process to get
approved (not yet found), and whether this is Shopify-specific or
protocol-wide (untested against a non-Shopify UCP store). Full writeup and
next steps: [`ucp-tool-gating-investigation.md`](ucp-tool-gating-investigation.md).
