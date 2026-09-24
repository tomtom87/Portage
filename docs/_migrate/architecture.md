## How the pieces fit together

```
Your backend
    ↓ implements
Portage::Ucp::Adapter (catalog/cart/checkout/order/identity methods)
    ↓ registered against
Portage::Ucp::CapabilityRegistry  (which capabilities does this adapter actually support?)
    ↓ used by
Portage::Ucp::Dispatcher          (routes a capability+action call to the Adapter method)
    ↓ wrapped by
Portage::Ucp::Mcp::Server.build   (generates MCP::Tool objects, one per advertised action)
    ↓ served over
stdio / Streamable HTTP (via the `mcp` gem)
    or a browser page's document.modelContext (WebMCP, via portage-ucp-webmcp)

Portage::Ucp::Manifest             (builds the signed /.well-known/ucp discovery doc)
    ↓ served by
Portage::Ucp::Rack::ManifestEndpoint

Portage::Ucp::Rack::WebhookEndpoint (HMAC-verified inbound order-lifecycle webhooks)
```

A capability (e.g. `dev.ucp.shopping.cart`) is only advertised if your `Adapter` overrides at least one of its backing methods — an unconfigured method just means that capability doesn't show up in the manifest or the MCP tool list, not a 500.
