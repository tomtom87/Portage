# portage-ucp-client

Client-side SDK for [`portage-ucp`](https://github.com/tomtom87/Portage/tree/main/portage-ucp)
— the other direction from every adapter gem. Every adapter gem lets a Ruby
program *expose* a commerce backend to agents (server side). This gem lets a
Ruby program *act as* the shopper's agent: connect to somebody else's
`/.well-known/ucp` manifest, or drive your own `Adapter` directly, and place an
order as the client.

Three transports behind one `Session` interface — callers never know which they
got:

| Transport | Use case |
|---|---|
| `Portage::Ucp::Client.for_adapter(adapter)` | Loopback over an in-process `Adapter` — no subprocess, no socket. Still runs the real authenticator/rate-limiter/`Dispatcher` stack, just without the wire hop. For driving your own store's `Adapter` directly. |
| `Portage::Ucp::Client.connect(command: ...)` | stdio, spawns a subprocess (an MCP server exe). |
| `Portage::Ucp::Client.connect(url: ...)` | Streamable HTTP, connects to a remote MCP endpoint. |
| `Portage::Ucp::Client.discover(url)` | Fetches `<url>/.well-known/ucp`, parses the manifest, and connects to whatever transport it advertises — the entry point for buying from a store you've never talked to before. |

Depends only on `portage-ucp` and the `mcp` gem's client half — no adapter gem is
a dependency.

## Installation

```ruby
# Gemfile
gem "portage-ucp-client"
```

```bash
bundle install
```

## Quickstart

```ruby
require "portage/ucp"
require "portage/ucp/client"

# Discover and connect to a live store you've never talked to before:
session = Portage::Ucp::Client.discover("https://your-shop.example")

products = session.search_catalog(query: "snowboard", limit: 5)
checkout = session.create_checkout(line_items: [{ product_id: products.first.id, quantity: 1 }])
completed = session.complete_checkout(checkout_id: checkout["id"], payment_token: "spt_1a2b3c...")
order = session.get_order(order_id: "gid://shopify/Order/9001")
```

`Session` generates an `idempotency_key` for you on every mutating call unless you
pass your own — retrying with the same key replays the cached result instead of
double-charging.

See the root README's
[detailed walkthrough](https://github.com/tomtom87/Portage#detailed-walkthrough-an-agent-buys-a-snowboard)
for the full runnable example (via the loopback transport) including
`requires_escalation` handling and `RawPanRejectedError`, and
[`portage-cli`](https://github.com/tomtom87/Portage/tree/main/portage-cli) for a
ready-made `portage buy <url>` command built on top of this gem.

## Development

```bash
bundle exec rspec
bundle exec rubocop
```

## License

[MIT](LICENSE) — Copyright (c) 2026 Tom Whitbread.
