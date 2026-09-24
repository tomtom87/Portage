# UCP overview

UCP (the [Universal Commerce Protocol](https://ucp.dev)) is a spec describing how a
commerce backend advertises what it can do — catalog, cart, checkout, order, and a handful
of Portage-owned extensions — as a set of named **capabilities** (`dev.ucp.shopping.cart`,
`dev.ucp.shopping.checkout`, and so on), each with a version and a list of actions. Portage
is an implementation of both sides of that conversation in Ruby:

- **Server side** (`portage-ucp` + an adapter gem): your backend implements a
  `Portage::Ucp::Adapter` subclass; the gem turns whichever methods you override into an
  advertised capability, a signed `/.well-known/ucp` manifest, and a set of MCP tools an
  agent can call. See [Architecture](../architecture.md) for the full request path and
  [Writing adapters](../writing-adapters.md) for the `Adapter` contract itself.
- **Client side** (`portage-ucp-client`): a shopper's agent discovers a manifest, connects
  over whichever transport it advertises (stdio, Streamable HTTP, or an in-process loopback
  for testing), and drives the same capability actions as tool calls. See
  [the walkthrough](../walkthrough.md) for a full buy end to end.

UCP is deliberately **capability-shaped, not platform-shaped**: an agent doesn't need to
know it's talking to Shopify vs. WooCommerce vs. a hand-rolled backend, only that
`dev.ucp.shopping.checkout` is advertised and what actions it exposes. That's also why
capability coverage varies by adapter — Etsy and Instagram, for instance, have no real
cart/checkout API to back, so they only ever advertise catalog and a redirect-link
checkout. The [capability coverage](../capability-coverage.md) page and the
[feature matrix](../adapters/feature-matrix.md) both cover exactly which capability each
bundled adapter can back for real, and why.

MCP ([Model Context Protocol](https://modelcontextprotocol.io)) is the transport UCP rides
on in this project: `Portage::Ucp::Mcp::Server.build` turns an advertised capability's
actions into `MCP::Tool` objects, served over stdio or Streamable HTTP via the `mcp` gem —
or, via `portage-ucp-webmcp`, over a browser page's own `document.modelContext` instead of a
separate server process (see [the WebMCP adapter page](../adapters/webmcp.md)).

Two more pieces worth knowing about before you go deeper:

- **The agent profile** (`meta.ucp-agent.profile`) — a document describing the *agent*
  making a call, distinct from the manifest describing the *business*. See
  [Agent profile](../agent-profile.md).
- **`/.well-known/ucp` itself** — why that path, how it differs from `llms.txt`, and what a
  platform's own native support (Shopify's Universal Commerce Agent app) already covers vs.
  leaves for this gem to fill in. See [Serving /.well-known/ucp](../well-known-ucp.md).

If a real UCP server starts rejecting every tool call with `Tool not found` once you attach
an agent profile, that's almost always a capability-id mismatch between the profile and the
server's registry, not a permissions problem — see the
[tool gating troubleshooting](../ucp-tool-gating-investigation.md) writeup, which
documents a real, corrected investigation into exactly that failure mode.
