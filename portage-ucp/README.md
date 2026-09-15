# portage-ucp

Protocol-only core gem: expose a commerce backend to AI shopping agents over **MCP**
([Model Context Protocol](https://modelcontextprotocol.io)) and **UCP**
([Universal Commerce Protocol](https://ucp.dev)) at once. Zero commerce-backend
dependencies — works with any backend that implements `Adapter`, Shopify or
otherwise. Adapter gems (`portage-ucp-shopify`, `portage-ucp-wix`, ...) are
consumers of this gem, not dependencies of it.

See the [root README](https://github.com/tomtom87/Portage#readme) for the full
walkthrough (an agent discovering a manifest and buying a snowboard end to end),
security model, and adapter comparison table. This README covers just what lives
in this gem.

## What it ships

| Class | Role |
|---|---|
| `Portage::Ucp::Adapter` | The contract your backend implements — override only the catalog/cart/checkout/order/identity methods you support; the rest stay unadvertised. |
| `Portage::Ucp::CapabilityRegistry` | Figures out which capabilities an `Adapter` actually backs. |
| `Portage::Ucp::Dispatcher` | Routes a capability+action call to the right `Adapter` method. |
| `Portage::Ucp::Mcp::Server` | Wraps an `Adapter` as an MCP server — one `MCP::Tool` per advertised action, stdio or Streamable HTTP. |
| `Portage::Ucp::Manifest` | Builds the signed `/.well-known/ucp` discovery document. |
| `Portage::Ucp::Rack::ManifestEndpoint` | Serves that manifest over Rack. |
| `Portage::Ucp::Rack::WebhookEndpoint` | HMAC-verified inbound order-lifecycle webhooks. |
| `Portage::Ucp::Security::Signature` / `Portage::Ucp::Rack::SignatureVerification` | Verifies RFC 9421 HTTP Message Signatures on inbound requests per UCP's signature spec — cryptographic proof the call carries a signed AP2/UCP authorization, not just an authenticated caller. Wrap your mounted MCP/UCP endpoint with the Rack middleware; verification runs before the body is parsed. |
| `Portage::Ucp::SchemaValidator` | Validates data against UCP's own vendored JSON Schemas/OpenRPC docs, offline. |
| `Portage::Ucp::Resolver` / `exe/portage-ucp-check` | Probes any store's homepage/`.well-known/ucp` and recommends the matching adapter gem. |
| `Portage::Ucp::Support::TransactionLog` | Durable pre/post-dispatch record of every `complete_checkout` call — reserved before dispatch, marked settled/failed after, so a crash mid-charge is diagnosable rather than silently lost. |
| `Portage::Ucp::Support::OrderLedger` | Durable snapshot written after settlement, alongside (not instead of) the transaction record — a failed snapshot write surfaces without flipping an already-settled charge to failed. |
| `Portage::Ucp::Confirmer` | Gate run just before `complete_checkout` dispatch, after `PolicyGuard`. `Confirmer::Terminal` blocks on stdin and fails closed on anything but an explicit `"y"`; `Confirmer::AutoApprove` is for specs/conformance kits that need a real `confirm!` without blocking; `Confirmer::Webhook` is an out-of-band transport (POST + poll a status URL, or a caller-supplied `wait:` callback) for a Slack/WhatsApp/etc. approval flow — same fail-closed-on-timeout contract, its own longer default timeout. |
| `Portage::Ucp::PolicyGuard` / `Portage::Ucp::Policy` | Per-transaction/rolling/velocity caps and a merchant allowlist, checked before `complete_checkout` dispatch; configured via `portage-cli`'s `portage policy show/set`. |
| `Portage::Ucp::PaymentEnrollmentGuard` | Validates every `create_payment_enrollment`/`get_payment_enrollment` result an `Adapter` returns — `status` must be `"pending"` (with a `setup_url`, no `payment_token`) or `"complete"` (with a `payment_token`, no `setup_url`). Runs automatically in `Dispatcher#call`. |
| `Portage::Ucp::Ap2::PaymentMandate` / `Portage::Ucp::Ap2::MandateGuard` | A typed shape for an AP2 payment mandate, and shape-only validation (required fields + expiry — not cryptographic verification) run automatically on any `mandate:` argument passed through `Dispatcher#call`. |

Security defaults are all locked down, not permissive-by-omission —
`UnconfiguredAuthenticator` rejects every mutating call until you configure a real
one, `PaymentTokenGuard` rejects raw card numbers before they reach your `Adapter`,
`PaymentEnrollmentGuard`/`Ap2::MandateGuard` reject malformed enrollments/mandates
before they cross the same boundary, and manifest signing is opt-in. Full detail in
the root README's
[Security hooks](https://github.com/tomtom87/Portage#security-hooks--nothing-is-permissive-by-default)
section.

## Installation

```ruby
# Gemfile
gem "portage-ucp"
```

```bash
bundle install
```

## Usage

```ruby
require "portage/ucp"

class MyAdapter < Portage::Ucp::Adapter
  def search_catalog(query:, limit:) = ...
  def get_product(product_id:) = ...
  def create_cart(line_items:, idempotency_key:) = ...
  # override only the capabilities you support
end

Portage::Ucp.configure do |config|
  config.authenticator = MyAuthenticator.new
  config.rate_limiter = MyRateLimiter.new
  config.business = { name: "Your Store", url: "https://your-shop.example" }
end

server = Portage::Ucp::Mcp::Server.build(adapter: MyAdapter.new)
server.start
```

See the root README's [Usage](https://github.com/tomtom87/Portage#usage)
and the [detailed walkthrough](https://github.com/tomtom87/Portage/blob/main/docs/walkthrough.md)
for the full agent-side conversation, manifest/webhook Rack mounting, and a real
adapter to model your own against.

## Swapping the store

`Support::TransactionLog` and `Support::OrderLedger` each accept a `store:`
(`Dispatcher.new(transaction_log:, order_ledger:)` is the injection point).
`FileStore` — whole-file `flock` + JSON, `chmod 0600` — is the shipped
default for both; nothing else ships today. Write your own subclass of
`Support::TransactionLog::Store` / `Support::OrderLedger::Store` for a real
database, Redis, or an in-memory double for tests — same posture as
`portage-ucp-journal`'s `Store`/`FileStore` seam, no bundled second backend
(see that gem's README). `path:`/`clock:` still work as a shorthand that
builds a `FileStore` under the hood, so existing callers are unaffected.

## Checking any store

```bash
bundle exec portage-ucp-check your-shop.example
```

Tries `/.well-known/ucp` first; falls back to platform detection and names the
matching `portage-ucp-<adapter>` gem, live-probing it if credentials are already in
env. See the root README's [Checking any store](https://github.com/tomtom87/Portage#checking-any-store)
section for sample output.

## Development

```bash
bundle exec rspec
bundle exec rubocop
```

See the [design log](https://github.com/tomtom87/Portage/blob/main/docs/design-log.md) for the
design rationale and decision history behind this project.

## License

[MIT](LICENSE) — Copyright (c) 2026 Tom Whitbread.
