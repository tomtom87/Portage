# Running Portage behind a proxy

`docs/plans/proxy-support.md` tracks the full design across four phases. Phases 0–3
are implemented and merged (`b6c8a4d`, `833c267`, `d3ac72c`, `d7bafa2`); this page is
Phase 4 — how to actually point Portage at the proxy topologies people run in
practice, and what to expect from each one. For the CLI flags/env vars themselves,
see [`portage-cli/README.md`](../portage-cli/README.md) (mirrored at
[CLI reference](cli-reference.md)).

Everything here is **outbound egress** (`forward`/`gateway` modes) except the last
section, which is **inbound** — a reverse proxy sitting in front of Portage's own
MCP/WebMCP endpoints.

## How it fits together

- `Portage::Ucp::Support::Connection.start` is the one seam every outbound call in
  `portage-cli`, `portage-ucp`, and the adapter gems goes through. It resolves a
  named **route** (`store`, `search`, `notify`, `payment`, `platform`, `probe`) to a
  proxy profile — a real proxy/gateway, an ordered chain of them, or `:direct` — via
  `Portage::Ucp::Support::ProxyConfig`.
- `Portage::Cli::ProxySettings` (portage-cli) resolves `--proxy*` flags,
  `PORTAGE_PROXY*` env vars, and `~/.portage/config.json`'s `"proxy"` section into
  that `ProxyConfig`, with **per-field** precedence: flag > env > config.json. A bare
  `--proxy URL` overrides only `default.url`, leaving config.json's `no_proxy`,
  `routes`, and `chains` exactly as configured.
- A route nobody configured falls back, in order, to the `default` profile, then to
  the plain `HTTPS_PROXY`/`HTTP_PROXY`/`NO_PROXY` env vars (resolved per the
  target's own scheme, unlike Ruby's own `:ENV` proxy mode — see the design-log's
  Phase 0 write-up for why that distinction matters). The **`payment` route is the
  one exception**: `ProxySettings` force-sets it to `:direct` unless you name a
  proxy for it explicitly (flag or `routes.payment` in config.json), so payment
  traffic never silently inherits a bare `$http_proxy` the way every other
  unconfigured route still does.
- Every mode's credentials are redacted to `http://***@host:port` everywhere Portage
  logs, raises, or reports them (`portage doctor`, `--json`, `ProxyError` messages) —
  never the real password.

Only `buy`, `find`, `compare`, `doctor`, and `payment enroll` accept `--proxy*`
flags — those are the network-touching commands. `portage orders reconcile` is a
read-only console helper in this codebase and doesn't take them.

## Corporate egress

The common case: an internal squid/proxy server every outbound request to a store
or search backend has to go through, usually with its own Basic-auth credentials,
sometimes with a corporate CA intercepting TLS for inspection.

```bash
portage buy https://shop.example --query "hoodie" \
  --proxy http://user:pass@egress.internal:3128 \
  --proxy-ca /etc/ssl/corp-ca.pem \
  --no-proxy localhost,127.0.0.1,.internal
```

Or, persisted in `~/.portage/config.json` so every invocation picks it up without
retyping the flags:

```json
{
  "proxy": {
    "default": {
      "mode": "forward",
      "url": "http://egress.internal:3128",
      "password_ref": "egress-proxy",
      "ca_file": "/etc/ssl/corp-ca.pem",
      "no_proxy": ["localhost", "127.0.0.1", ".internal"]
    }
  }
}
```

`password_ref` resolves through macOS Keychain or Linux Secret Service (service
`portage-cli-proxy`, kept deliberately separate from `payment_methods`' own
Keychain entries — see `ProxySettings::PasswordRef`), so the credential itself
never has to sit in plaintext in `config.json`. If you do put a real password in
the URL instead, `portage doctor` flags it as a `proxy_credentials` warning.

Because the corporate CA in this example is configured via `ca_file`, and because
this profile has no explicit `routes.payment` entry, `payment` traffic still goes
**direct** — not through this proxy — even though `default` is set. If your
corporate policy genuinely requires payment traffic to also transit this proxy,
name it explicitly:

```json
{ "proxy": { "routes": { "payment": "default" } } }
```

Doing so makes `portage doctor` raise a `proxy_payment_intercept` warning, since a
`ca_file`- or gateway-mode proxy on the payment route can read plaintext payment
tokens in transit.

## A rotating residential proxy pool

Most residential/rotating proxy providers hand you a single stable endpoint that
does the rotation on their side (a new exit IP per connection or per interval), so
this looks like corporate egress from Portage's perspective — one `forward` URL:

```json
{
  "proxy": {
    "routes": {
      "store": "http://user:pass@rotating-pool.example:7000",
      "search": "http://user:pass@rotating-pool.example:7000"
    }
  }
}
```

**Warning: many stores treat this traffic as bot traffic.** A request arriving from
a residential/rotating IP range that a storefront's bot-detection service
recognizes (Cloudflare, PerimeterX, Shopify's own checks, etc.) may be challenged,
rate-limited, or blocked outright, independent of anything Portage does right —
proxying is not a way around bot detection, and Portage doesn't try to make it one.

`UserAgent` (`PORTAGE_USER_AGENT` / config.json's `user_agent`) still names Portage
honestly on every request, whatever proxy or route carries it — `proxy_headers`
and `forward_headers` are explicitly forbidden from ever touching the `User-Agent`
header (`ProxyConfig::PROTECTED_HEADER_NAMES`; an attempt to override it via proxy
config raises a `ConfigError` at load time, not a silent override). Routing traffic
through a rotating pool changes *where* a request egresses from, never *what it
claims to be*. See the plan's non-goals: no bot-detection evasion, no `User-Agent`
spoofing.

## An API gateway

A URL-rewriting gateway — an internal scraping-compliant relay, or a vendor's API
gateway product — that takes requests at its own base URL and needs the real
target named some other way. `gateway` mode supports three shapes:

```json
{
  "proxy": {
    "routes": {
      "platform": {
        "mode": "gateway",
        "url": "https://gw.example/fetch",
        "target_header": "X-Target-URL"
      }
    }
  }
}
```

- `target_header` — the real target URL goes in this request header.
- `target_param` — the real target URL goes in this query parameter instead.
- neither set — falls back to a path prefix: `{gateway base path}/{target host}{target path}`.

TLS terminates **at the gateway**, not at the real target — Portage dials the
gateway's own host/port directly and never re-establishes a separate TLS session
to the target. Every redirect a gateway-proxied response returns is followed
*through the gateway itself* (`Connection`'s own redirect handling re-resolves the
same route on each hop), never degraded to a direct connection — a gateway route
can't accidentally leak a request straight to the target once the caller stops
paying attention to redirects.

Chaining a `forward` egress proxy in front of a `gateway` is a single native
Net::HTTP proxy hop and needs no special configuration — name the gateway as the
route's `url` and set `default` (or the route's own `chain`) to the forward hop;
`forward → forward → …` (nested `CONNECT`) works the same way via
`--proxy-chain URL,URL,...` or a named `chains` entry in config.json.

## mitmproxy for debugging

Point a single command at a local `mitmproxy`/`mitmdump` instance to see every
request Portage makes, without touching anything else in your config:

```bash
mitmproxy -p 8080   # or mitmdump -p 8080

portage buy --query "hoodie" --dry-run --json \
  --proxy http://localhost:8080 \
  --proxy-ca ~/.mitmproxy/mitmproxy-ca-cert.pem
```

`--proxy-ca` trusts mitmproxy's own generated CA for the run, so an
`https://` target doesn't fail TLS verification against mitmproxy's
intercepting certificate. This is a `forward`-mode profile like any other — no
different from pointing at a real corporate egress proxy, which is exactly the
point: debugging with mitmproxy exercises the same code path production traffic
does.

`portage doctor` also probes the configured proxy's own reachability (a real
`CONNECT`/GET through it, via the same `Support::Connection` code path a real
request uses) — useful to confirm mitmproxy is actually listening before running
a full `buy`:

```bash
portage doctor --proxy http://localhost:8080 --proxy-ca ~/.mitmproxy/mitmproxy-ca-cert.pem
```

## nginx/Cloudflare in front of the MCP/WebMCP endpoints

This is the **inbound** direction — a reverse proxy or CDN sitting in front of
Portage's own server-side endpoints (WebMCP's `CallEndpoint`, `Rack::WebhookEndpoint`,
or whatever HTTP transport fronts `Mcp::Server`). Without any configuration, every
one of these endpoints ignores `X-Forwarded-*`/`Forwarded` entirely and reads the
literal socket peer as the client — safe, but wrong once a real reverse proxy is in
front, since every request then appears to come from the proxy's own address.

`Portage::Ucp::Rack::ForwardedRequest` is fail-closed: it only trusts
`X-Forwarded-For`/`-Proto`/`-Host`/`Forwarded` from an explicitly configured
`trusted_proxies` list of CIDRs (bare IPs count as `/32`/`/128`). With no
`trusted_proxies` set (the default, `[]`), nothing changes — every forwarded header
is ignored outright, not partially trusted.

Wire it in when constructing the endpoint, naming your own reverse proxy or load
balancer's address range — never a wildcard, never the public Internet:

```ruby
Portage::Ucp::WebMcp::Rack::CallEndpoint.new(
  catalog: catalog,
  trusted_proxies: ["10.0.0.0/8", "127.0.0.1/32"],       # nginx/your LB's own subnet
  forwarded_host_allowed: ["shop.example"],               # only if terminating TLS in front
  passthrough_headers: ["traceparent", "x-request-id"],   # optional — see below
  passthrough_forwarded: "append"
)

Portage::Ucp::Rack::WebhookEndpoint.new(
  secret: webhook_secret,
  on_order_event: ->(order) { ... },
  trusted_proxies: ["10.0.0.0/8", "127.0.0.1/32"]
)
```

A representative nginx fragment in front of either endpoint:

```nginx
location /webmcp/ {
    proxy_pass http://127.0.0.1:9292;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Host $host;
}
```

Cloudflare (or any CDN) in front of nginx works the same way — nginx trusts
Cloudflare's published IP ranges as `trusted_proxies` at *its own* level (the usual
`real_ip` module configuration, outside Portage's scope), and Portage in turn only
needs to trust nginx's own address, since nginx is the peer Portage's process
actually sees.

Once trusted, the resolved client IP reaches every consumer that needs the real
caller rather than the proxy's address: `server_context[:client_ip]` for a host
app's `RateLimiter`/`Authenticator`, and the order-event logging in
`WebhookEndpoint`. `X-Forwarded-Host` can additionally stand in for "the endpoint's
own origin" in the `Origin` same-origin check — but **only** when the peer is
trusted *and* the forwarded host is explicitly listed in `forwarded_host_allowed`.
This never widens `allowed_origins` itself; a forwarded host that isn't allowlisted
(or that arrives from an untrusted peer) has no effect at all, so `Origin` spoofing
via a forged `X-Forwarded-Host` isn't possible even from a client that can reach
the endpoint directly, bypassing nginx.

### Passthrough: carrying inbound headers onto Portage's own outbound calls

When Portage is one hop in a longer chain — a reverse proxy in front of it, and its
own outbound calls (to the store, to a payment gateway) going on through another
proxy or gateway — `passthrough_headers:` names which of the *inbound* request's
headers should ride along on *outbound* calls made while serving that request
(trace/correlation headers like `traceparent`/`X-Request-Id`, or a tenant/routing
header a downstream proxy keys on). Only from a trusted peer; never a protected
header (`Authorization`, `User-Agent`, `X-Shopify-*-Access-Token`, the payment
token header) — naming one raises at construction time via
`ForwardedRequest.validate_passthrough!`, not a silent drop.

`passthrough_forwarded:` (`"append"`, `"replace"`, or `"drop"`, the default) controls
whether the resolved client IP is also added to the outbound `Forwarded`/
`X-Forwarded-For` chain on those same calls. This is carried via a fiber-local
`Support::PassthroughContext`, set for the duration of the inbound request and
cleared once it finishes — nothing leaks between requests or fibers, and a
single-threaded fiber-scheduled server (Falcon, the `mcp` gem's async transport)
serving several concurrent requests on one thread never mixes them up.

## Known gaps

Two outbound call sites in `portage-ucp-client` don't go through
`Support::Connection`/`ProxyConfig` yet, so none of the CLI flags/config.json/routes
above reach them:

- **`Client.discover`'s Faraday `proxy:` option** is a raw pass-through to
  `Faraday::Connection#proxy=` (a bare URL string, Hash, or URI) — Faraday resolves
  it (or its own env-proxy defaults) independently of `ProxyConfig`, so a
  `--proxy`/`routes.store` set for `portage buy` doesn't automatically apply to a
  raw `Portage::Ucp::Client.discover`/`.connect` call made directly against this
  gem.
- **`Client.fetch_manifest`** — the manifest GET `Client.discover` makes before it
  ever reaches Faraday — is still a bare `Net::HTTP.get_response`, so it inherits
  Ruby stdlib's `http_proxy`-only env-proxy quirk (see the root README's own
  "Running behind a proxy" section) rather than picking up `ProxyConfig` or even
  correctly reading `HTTPS_PROXY` for an `https://` manifest URL.

Both are pre-existing gaps in `portage-ucp-client`'s own transport, not something
Phases 1–3 introduced or fixed — call it out if you're relying on this gem directly
rather than through `portage-cli`.
