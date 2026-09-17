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
run. Until that's sorted, `.env.example`'s `PORTAGE_AGENT_PROFILE` points at
`raw.githubusercontent.com/tomtom87/Portage/main/portage-cli/agent-profile/agent-profile.json`
instead — same checked-in JSON, served straight off the repo with no Pages
build required. Confirmed live: HTTPS, no redirect, `Cache-Control:
max-age=300`, `application/json`; a real Shopify store accepted it and got
past the agent-profile check. Switch back to the Pages URL once Actions is
enabled — GitHub's CDN caching on raw file serving isn't a documented
guarantee the way Pages is.

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
