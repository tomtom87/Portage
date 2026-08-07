# Detailed walkthrough: an agent buys a snowboard

A shopper tells their AI agent: *"Find me a snowboard under $600 and buy it."* This shopper has no account with you, no API key, no relationship with your store beyond finding it — none of that is required on their end. Their agent discovered your store's manifest at `/.well-known/ucp`, saw `dev.ucp.shopping.catalog`/`cart`/`checkout` advertised, and connects over MCP using nothing but that public manifest.

Below is that agent's side of the conversation — runnable today via `portage-ucp-client`'s loopback transport (`Client.for_adapter`), which drives your real `Adapter` in-process through the exact same `Authenticator`/`RateLimiter`/`Dispatcher` stack a real stdio/HTTP connection would, just without the wire hop. Swap `Client.for_adapter(adapter)` for `Client.discover("https://your-shop.example")` and this is unchanged for a real remote store — that's the point of one client interface across all three transports (§ `portage-ucp-client`).

```ruby
require "portage/ucp"
require "portage/ucp/client"

# In real life: session = Portage::Ucp::Client.discover("https://your-shop.example")
# Here: driving your own Adapter directly, in-process, for a fully runnable example.
session = Portage::Ucp::Client.for_adapter(adapter, authenticator: my_authenticator)

# 1. Search the catalog
products = session.search_catalog(query: "snowboard", limit: 5)
# => [#<Portage::Ucp::Product id: "gid://shopify/Product/1", title: "Powder Chaser 158cm",
#      price: #<Money amount_minor: 54900, currency: "USD">, available: true, ...>, ...]

# 2. Pull full detail on the one that fits the budget
product = session.get_product(product_id: products.first.id)
# => variants: [{ id: "gid://shopify/ProductVariant/11", title: "158cm", available: true, price: ... }]

# 3. Create a checkout for the variant picked — idempotency_key is generated for you
checkout = session.create_checkout(line_items: [{ product_id: "gid://shopify/ProductVariant/11", quantity: 1 }])
# => { "id" => "gid://shopify/Cart/abc", "status" => "incomplete", "totals" => [...], ... }

# A real checkout can come back requires_escalation instead — that's normal data (a link
# to follow), not a failure. Branch on it before assuming you can complete_checkout next.
if checkout["status"] == "requires_escalation"
  puts "Buyer must act first: #{checkout['links'].first['url']}"
else
  # 4. Complete checkout with a tokenized payment credential — never a raw card number.
  # PaymentTokenGuard runs client-side automatically; a raw PAN raises RawPanRejectedError
  # before it ever reaches the wire, let alone your Adapter.
  completed = session.complete_checkout(checkout_id: checkout["id"], payment_token: "spt_1a2b3c...")
  # => { "id" => "gid://shopify/Cart/abc", "status" => "completed", ... }

  # 5. Fetch the resulting order, if you have an order id to look up
  order = session.get_order(order_id: "gid://shopify/Order/9001")
  # => { "id" => ..., "checkout_id" => "gid://shopify/Cart/abc",
  #      "permalink_url" => "https://your-shop.example/...",
  #      "fulfillment" => { "expectations" => [...], "events" => [] }, "totals" => [...] }
end
```

Reusing the same `idempotency_key` on a retry (dropped connection, agent double-submit) replays the cached result instead of charging twice — you don't have to think about this, `Session` generates one per mutating call unless you pass your own.

On the server side, none of this changed: `Authenticator#call` and `RateLimiter#check!` still gate every mutating call before it reaches your `Adapter`, exactly as before — the loopback transport runs the real `Portage::Ucp::Mcp::Server` stack, it doesn't bypass it. Meanwhile `Portage::Ucp::Rack::WebhookEndpoint` receives Shopify's fulfillment updates independently and calls your `on_order_event` callback as tracking events land — the shopper's agent can poll `get_order` again later to answer "where's my snowboard?" without you building that plumbing yourself.

## Serving the discovery manifest and webhooks

The tool calls above only happen because the agent found your manifest first. Serve it (and inbound order webhooks) over Rack:

```ruby
# config.ru
manifest = Portage::Ucp::Manifest.new(adapter: adapter)

map "/.well-known/ucp" do
  run Portage::Ucp::Rack::ManifestEndpoint.new(manifest: manifest)
end

map "/webhooks/ucp/orders" do
  run Portage::Ucp::Rack::WebhookEndpoint.new(
    secret: ENV.fetch("UCP_WEBHOOK_SECRET"),
    on_order_event: ->(order) { MyOrderSync.call(order) }
  )
end
```

`ManifestEndpoint` refuses to serve payment-handler declarations over plaintext HTTP (set `allow_insecure: true` for local dev only). `WebhookEndpoint` verifies an HMAC-SHA256 signature against the raw body before parsing anything.
