# portage-ucp API

This page is the API reference for the `portage-ucp` gem (version 0.10.0), the protocol core that adapters and store backends plug into.

The gem needs Ruby 3.2 or later. It depends on `base64`, `json_schemer`, `mcp` and `rack`. For a guided introduction, see [library usage](../library-usage.md) and [writing adapters](../writing-adapters.md).

## Loading and configuration

```ruby
require "portage/ucp"
```

That one require loads everything in the core gem except the RSpec conformance kit (`require "portage/ucp/rspec"`). If Rails is already loaded, it also registers the `portage:ucp:install` generator.

`Portage::Ucp.configure` yields the process-wide `Portage::Ucp::Configuration`. `Portage::Ucp.configuration` returns it.

```ruby
Portage::Ucp.configure do |config|
  config.authenticator = ->(server_context) { ... }
  config.business = { name: "Your Store", url: "https://shop.example" }
end
```

Every collaborator can also be passed explicitly to `Mcp::Server.build` and `Manifest.new`. Configuration only supplies their defaults.

| Option | Default | Used by |
|---|---|---|
| `registry` | `CapabilityRegistry.default` | `Mcp::Server.build`, `Manifest.new` |
| `authenticator` | `UnconfiguredAuthenticator.new` (rejects every mutating call) | `Mcp::Server.build` |
| `rate_limiter` | `NullRateLimiter.new` | `Mcp::Server.build` |
| `logger` | `Logger.new($stdout)` | `Mcp::Server.build`, `Dispatcher.new`, `Rack::WebhookEndpoint`, `Rack::SignatureVerification` |
| `business` | `nil` | `Manifest.new` |
| `signer` | `nil` | `Manifest.new` |
| `signing_keys` | `[]` | `Manifest.new` |
| `payment_handlers` | `[]` | `Manifest.new` |
| `services` | `[]` | `Manifest.new` |
| `mandate_trusted_keys` | `nil` | `Dispatcher.new` (`mandate_trust_keys:`) |
| `require_mandate_signature` | `false` | `Dispatcher.new` |
| `idempotency_provider` | `nil` (each adapter instance gets its own `MemoryStore`) | `Support::Idempotency` |
| `tracer` | `nil` | `Observability.log`. Anything that responds to `#in_span(name, attributes:)`. |

Do not set `idempotency_provider` to `Support::Idempotency::FileStore` in a long-lived server. `FileStore` holds one file lock across the whole deduplicated call and never evicts entries. It is meant for a short-lived CLI process.

### PORTAGE_UCP_CONFIG

The core gem does not read `PORTAGE_UCP_CONFIG`. The executables in the adapter gems do. Each one runs `require ENV["PORTAGE_UCP_CONFIG"] if ENV["PORTAGE_UCP_CONFIG"]` after loading `portage/ucp`. Point it at a Ruby file that calls `Portage::Ucp.configure`:

```bash
PORTAGE_UCP_CONFIG=./config/portage_ucp.rb bundle exec portage-ucp-woocommerce
```

If you write your own executable, copy that line.

Source: `portage-ucp/lib/portage/ucp.rb`, `portage-ucp/lib/portage/ucp/configuration.rb`, `portage-ucp/lib/portage/ucp/railtie.rb`

## The Adapter contract

Subclass `Portage::Ucp::Adapter` and override the methods for the capabilities you support. Every method on the base class raises `Portage::Ucp::NotImplementedError`. No method is required. An unoverridden method leaves its capability out of the manifest and out of the MCP tool list.

All parameters are keyword arguments. Mutating methods take `idempotency_key:` and must dedupe retries (see [Idempotency](#idempotency-and-escalation)).

### Catalog (`dev.ucp.shopping.catalog`)

| Method | Signature | Returns | Notes |
|---|---|---|---|
| `search_catalog` | `search_catalog(query:, limit:)` | `CatalogSearchResult` | |
| `get_product` | `get_product(product_id:)` | `ProductDetail` or `nil` | `nil` when not found. |
| `lookup_catalog` | `lookup_catalog(product_ids:)` | `CatalogSearchResult` | Batch fetch. |

### Cart (`dev.ucp.shopping.cart`)

| Method | Signature | Returns | Notes |
|---|---|---|---|
| `get_cart` | `get_cart(cart_id:)` | `Cart` | |
| `create_cart` | `create_cart(line_items:, idempotency_key:, discount_codes: nil)` | `Cart` | `line_items` is an array of request-shaped hashes such as `{product_id:, quantity:}`. |
| `update_cart` | `update_cart(cart_id:, line_items:, idempotency_key:, discount_codes: nil)` | `Cart` | Full replacement of `line_items`. |
| `cancel_cart` | `cancel_cart(cart_id:, idempotency_key:)` | `Cart` | |

### Checkout (`dev.ucp.shopping.checkout`)

| Method | Signature | Returns | Notes |
|---|---|---|---|
| `create_checkout` | `create_checkout(line_items:, idempotency_key:, discount_codes: nil, fulfillment: nil)` | `Checkout` | |
| `get_checkout` | `get_checkout(checkout_id:)` | `Checkout` | |
| `update_checkout` | `update_checkout(checkout_id:, line_items:, idempotency_key:, discount_codes: nil, fulfillment: nil)` | `Checkout` | Full replacement of `line_items`. |
| `complete_checkout` | `complete_checkout(checkout_id:, payment_token:, idempotency_key:, mandate: nil)` | `Checkout` | `payment_token` is a single-use token, never a raw card number. Raise `OutOfStockError` if a line item is no longer available. `mandate` is an `Ap2::PaymentMandate`, already validated by `Dispatcher`. |
| `cancel_checkout` | `cancel_checkout(checkout_id:, idempotency_key:)` | `Checkout` | |

`discount_codes:` and `fulfillment:` are `nil` when the request did not touch them. An adapter that does not declare support (see [Extension capabilities](#extension-capabilities)) never receives anything else.

### Order (`dev.ucp.shopping.order`)

| Method | Signature | Returns | Notes |
|---|---|---|---|
| `get_order` | `get_order(order_id:)` | `Order` or `nil` | |
| `cancel_order` | `cancel_order(order_id:, idempotency_key:, reason: nil)` | `Order` | `reason` is free text. |
| `request_return` | `request_return(order_id:, line_items:, idempotency_key:, reason: nil)` | `Order` | `line_items` is an array of `{id:, quantity:}` hashes. Show the request as a `pending` `Adjustment`. |
| `refund_order` | `refund_order(order_id:, line_items:, idempotency_key:, reason: nil)` | `Order` | |

### Identity (`dev.ucp.shopping.identity`)

| Method | Signature | Returns | Notes |
|---|---|---|---|
| `link_identity` | `link_identity(oauth_token:)` | `Identity` | |

### Portage extensions (`app.portage-ucp.*`)

These are not part of the UCP spec.

| Method | Signature | Returns | Notes |
|---|---|---|---|
| `reorder` | `reorder(order_id:, idempotency_key:)` | `ReorderResult` or `nil` | `nil` if the order is not found. Drop unavailable items and report them in `unavailable_items`. |
| `create_payment_enrollment` | `create_payment_enrollment(idempotency_key:, mandate: nil)` | `PaymentEnrollment` | Returns a `setup_url`. Card data never enters this process. |
| `get_payment_enrollment` | `get_payment_enrollment(enrollment_id:)` | `PaymentEnrollment` or `nil` | |
| `save_payment_method` | `save_payment_method(oauth_token:, payment_token:, idempotency_key:)` | `PaymentMethodRef` | |
| `list_payment_methods` | `list_payment_methods(oauth_token:)` | `Array<PaymentMethodRef>` | |
| `delete_payment_method` | `delete_payment_method(oauth_token:, payment_method_id:, idempotency_key:)` | `Boolean` | |
| `save_address` | `save_address(oauth_token:, address:, idempotency_key:)` | `SavedAddress` | |
| `list_addresses` | `list_addresses(oauth_token:)` | `Array<SavedAddress>` | |
| `delete_address` | `delete_address(oauth_token:, address_id:, idempotency_key:)` | `Boolean` | |
| `delete_shopper_data` | `delete_shopper_data(oauth_token:, idempotency_key:)` | `ShopperDataErasure` | Must be safe to repeat. Forward the deletion to the platform. |

`oauth_token:` is the authorization boundary on every saved-payment, saved-address and shopper-data method, including the two `list_*` reads. Read-only calls skip authentication (see [MCP server](#mcp-server)), so the token is what protects them.

### Extension capabilities

Two capabilities add a parameter to existing actions instead of adding actions of their own. They are declared with predicate methods on the adapter:

| Method | Signature | Returns | Notes |
|---|---|---|---|
| `discount_codes_supported?` | `discount_codes_supported?` | `Boolean` | Default `false`. Advertises `dev.ucp.shopping.discount`. |
| `fulfillment_supported?` | `fulfillment_supported?` | `Boolean` | Default `false`. Advertises `dev.ucp.shopping.fulfillment`. |

### How capabilities are declared

You do not declare capabilities by hand. `Capability#advertised_for?(adapter)` returns true when either of these holds:

- The capability has a predicate (discount, fulfillment) and the adapter's predicate method returns true.
- At least one of the capability's backing methods is overridden, meaning its owner is not `Portage::Ucp::Adapter`.

So overriding a single method advertises the whole capability, and the MCP server then exposes every action of that capability. Methods you did not override raise `NotImplementedError` when called.

Source: `portage-ucp/lib/portage/ucp/adapter.rb`, `portage-ucp/lib/portage/ucp/capability.rb`

## Value objects

All value objects are `Data.define` classes in `Portage::Ucp`. Constructors take keyword arguments. Most response objects have `to_wire_h`, which returns a string-keyed hash. Optional attributes default as shown.

Amounts inside `Total`, `Item` and `LineItem` are bare integers in minor units (cents for USD). The parent object's `currency` applies.

Catalog:

| Class | Attributes |
|---|---|
| `Price` | `amount`, `currency` |
| `PriceRange` | `min`, `max` (both `Price`) |
| `Description` | `plain: nil`, `html: nil`, `markdown: nil` |
| `Category` | `value`, `taxonomy: nil` |
| `Media` | `type`, `url`, `alt_text: nil`, `width: nil`, `height: nil` |
| `OptionValue` | `label`, `id: nil` |
| `ProductOption` | `name`, `values` |
| `SelectedOption` | `name`, `label`, `id: nil` |
| `Rating` | `value`, `scale_max`, `scale_min: 1`, `count: nil` |
| `Variant` | `id`, `title`, `description`, `price`, `sku: nil`, `barcodes: []`, `list_price: nil`, `availability: nil`, `options: []`, `media: []`, `tags: []`, `metadata: nil` |
| `Product` | `id`, `title`, `description`, `price_range`, `variants`, `handle: nil`, `url: nil`, `categories: []`, `list_price_range: nil`, `media: []`, `options: []`, `tags: []`, `metadata: nil`, `rating: nil` |
| `CatalogSearchResult` | `products`, `messages: []` |
| `ProductDetail` | `product` |

Cart, checkout and order:

| Class | Attributes |
|---|---|
| `Total` | `type`, `amount`, `display_text: nil` |
| `Item` | `id`, `title`, `price`, `image_url: nil` |
| `LineItem` | `id`, `item`, `quantity`, `totals` |
| `Link` | `type`, `url`, `title: nil` |
| `AppliedDiscount` | `title`, `amount`, `code: nil`, `automatic: false`, `allocation_method: nil`, `priority: nil`, `provisional: false`, `eligibility: nil`, `allocations: []` |
| `Discounts` | `codes: []`, `applied: []` |
| `Cart` | `id`, `line_items`, `currency`, `totals`, `discounts: Discounts.new` |
| `Checkout` | `id`, `status`, `line_items`, `currency`, `totals`, `links`, `order: nil`, `discounts: Discounts.new`, `fulfillment: CheckoutFulfillment.new` |
| `OrderConfirmation` | `id`, `permalink_url`, `label: nil` (goes in `Checkout#order`) |
| `OrderLineItem` | `id`, `item`, `quantity`, `totals`, `status`, `parent_id: nil`. `quantity` is a hash with `:total` and `:fulfilled`, and optionally `:original`. |
| `Expectation` | `id`, `line_items`, `method_type`, `destination`, `description: nil`, `fulfillable_on: nil` |
| `FulfillmentEvent` | `id`, `occurred_at`, `type`, `line_items`, `tracking_number: nil`, `tracking_url: nil`, `carrier: nil`, `description: nil` |
| `Fulfillment` | `expectations: []`, `events: []` (the order's post-purchase container) |
| `Adjustment` | `id`, `type`, `occurred_at`, `status`, `line_items: nil`, `totals: nil`, `description: nil` |
| `Order` | `id`, `checkout_id`, `permalink_url`, `line_items`, `fulfillment`, `currency`, `totals`, `adjustments: []` |

Fulfillment selection on a checkout:

| Class | Attributes |
|---|---|
| `PostalAddress` | `extended_address`, `street_address`, `address_locality`, `address_region`, `address_country`, `postal_code`, `first_name`, `last_name`, `phone_number` (all `nil` by default) |
| `ShippingDestination` | `id`, `address` |
| `RetailLocation` | `id`, `name`, `address: nil` |
| `FulfillmentOption` | `id`, `title`, `totals`, `description: nil`, `carrier: nil`, `earliest_fulfillment_time: nil`, `latest_fulfillment_time: nil` |
| `FulfillmentGroup` | `id`, `line_item_ids`, `options: []`, `selected_option_id: nil` |
| `FulfillmentMethod` | `id`, `type`, `line_item_ids`, `destinations: []`, `selected_destination_id: nil`, `groups: []` |
| `FulfillmentAvailableMethod` | `type`, `line_item_ids`, `fulfillable_on: nil`, `description: nil` |
| `CheckoutFulfillment` | `shipping_methods: []`, `available_methods: []` (wire key is `methods`) |

`Checkout#status` is a string. The values named in the source are `incomplete`, `requires_escalation`, `ready_for_complete`, `complete_in_progress`, `completed` and `canceled`.

Portage extensions and helpers:

| Class | Attributes |
|---|---|
| `Identity` | `subject`, `email`, `linked_at` |
| `UnavailableReorderItem` | `item_id`, `title`, `reason` |
| `ReorderResult` | `cart`, `unavailable_items: []` |
| `PaymentEnrollment` | `id`, `status`, `setup_url: nil`, `payment_token: nil`, `expires_at: nil`, `mandate: nil` |
| `PaymentMethodRef` | `id`, `psp_reference`, `brand: nil`, `last4: nil`, `expires_at: nil`, `created_at: nil` |
| `SavedAddress` | `id`, `address`, `created_at` |
| `ShopperDataErasure` | `subject`, `payment_methods_deleted`, `addresses_deleted`, `identity_unlinked` |
| `Money` | `amount_minor`, `currency` (internal arithmetic only; never on the wire) |
| `Ap2::PaymentMandate` | `amount`, `currency`, `merchant`, `expires_at`, `signature`, `kid: nil` |

`WireEnvelope.wrap(capability_name, payload_hash)` adds the `ucp` envelope (`{"version" => "2026-08-25"}`, plus `payment_handlers` for checkout) to cart, checkout, order and catalog payloads. `Dispatcher` calls it for you.

Source: `portage-ucp/lib/portage/ucp/value_objects.rb`, `portage-ucp/lib/portage/ucp/wire_envelope.rb`, `portage-ucp/lib/portage/ucp/ap2/mandate.rb`

## Capability registry and manifest

### Capabilities

`Portage::Ucp::Capability.new(name:, version:, actions:, predicate: nil)` maps action names to adapter method names. `Capabilities::ALL` holds the built-in set, and every version is `"1"`.

| Name | Actions |
|---|---|
| `dev.ucp.shopping.catalog` | `search_catalog`, `get_product`, `lookup_catalog` |
| `dev.ucp.shopping.cart` | `create_cart`, `get_cart`, `update_cart`, `cancel_cart` |
| `dev.ucp.shopping.checkout` | `create_checkout`, `get_checkout`, `update_checkout`, `complete_checkout`, `cancel_checkout` |
| `dev.ucp.shopping.order` | `get_order`, `cancel_order`, `request_return`, `refund_order` |
| `dev.ucp.shopping.identity` | `link_identity` |
| `dev.ucp.shopping.discount` | none (predicate `discount_codes_supported?`) |
| `dev.ucp.shopping.fulfillment` | none (predicate `fulfillment_supported?`) |
| `app.portage-ucp.reorder` | `reorder` |
| `app.portage-ucp.payment_enrollment` | `create_payment_enrollment`, `get_payment_enrollment` |
| `app.portage-ucp.payment_method` | `save_payment_method`, `list_payment_methods`, `delete_payment_method` |
| `app.portage-ucp.saved_address` | `save_address`, `list_addresses`, `delete_address` |
| `app.portage-ucp.shopper_data` | `delete_shopper_data` |

### Registry

| Method | Signature | Returns | Notes |
|---|---|---|---|
| `CapabilityRegistry.new` | `CapabilityRegistry.new(capabilities:)` | registry | |
| `CapabilityRegistry.default` | `CapabilityRegistry.default` | registry | Wraps `Capabilities::ALL`. |
| `#advertised` | `advertised(adapter)` | `Array<Capability>` | Only the capabilities the adapter backs. |
| `#find` | `find(name)` | `Capability` or `nil` | |

### Manifest

`Portage::Ucp::Manifest` builds the `/.well-known/ucp` document. For the wire format see [well-known UCP](../well-known-ucp.md). For which capabilities each bundled adapter covers, see [capability coverage](../capability-coverage.md).

| Method | Signature | Returns | Notes |
|---|---|---|---|
| `Manifest.new` | `Manifest.new(adapter:, business:, registry:, payment_handlers:, signing_keys:, signer:, services:)` | manifest | Every keyword except `adapter:` defaults to the matching `Portage::Ucp.configuration` value. |
| `#to_h` | `to_h` | `Hash` | `{ ucp: { version:, business:, services:, capabilities:, payment_handlers: [, signature:] }, keys: [...] }` |

`Manifest::UCP_VERSION` is `"2026-04-08"`. `capabilities` is a hash keyed by capability name, each value `[{ version: "1" }]`.

Signing is optional. The gem never generates or stores keys. Pass a `signer` that responds to `#kid` and `#sign(canonical_json_string)`. `sign` returns raw signature bytes. The manifest adds `signature: { kid:, value: <strict base64> }` over `JSON.generate` of the `ucp` hash. The gem does not pick an algorithm. Publish the matching public keys in `signing_keys`; the manifest serves them as `keys`.

### Serving the manifest

```ruby
manifest = Portage::Ucp::Manifest.new(adapter: adapter)
map("/.well-known/ucp") { run Portage::Ucp::Rack::ManifestEndpoint.new(manifest: manifest) }
```

`Rack::ManifestEndpoint.new(manifest:, allow_insecure: false)` answers `GET` with the JSON document and any other verb with 404. It does not check the request path, so mount it yourself at `/.well-known/ucp`. When the manifest lists any `payment_handlers` and the request is not TLS, it answers status 496 instead. Pass `allow_insecure: true` only for local development.

Source: `portage-ucp/lib/portage/ucp/capability_registry.rb`, `portage-ucp/lib/portage/ucp/capabilities/`, `portage-ucp/lib/portage/ucp/manifest.rb`, `portage-ucp/lib/portage/ucp/rack/manifest_endpoint.rb`

## Dispatcher

`Portage::Ucp::Dispatcher` routes a capability and action to an adapter method and wraps the result. `Mcp::Server` uses it for every tool call. You can also call it directly, for example in specs.

| Method | Signature | Returns | Notes |
|---|---|---|---|
| `Dispatcher.new` | `Dispatcher.new(adapter:, registry: CapabilityRegistry.default, logger: Portage::Ucp.configuration.logger, shop: nil, transaction_log: Support::TransactionLog.new, policy: Policy.load, confirmer: Confirmer::Terminal.new, order_ledger: Support::OrderLedger.new, journal: nil, mandate_trust_keys: Portage::Ucp.configuration.mandate_trusted_keys, require_mandate_signature: Portage::Ucp.configuration.require_mandate_signature)` | dispatcher | |
| `#call` | `call(capability:, action:, arguments: {}, correlation_id: nil)` | `{ content:, structuredContent: }` | `arguments` is a hash with symbol keys. |

Order of checks in `#call`:

1. Raise `UnknownCapabilityError` if the registry does not know the capability.
2. Raise `CapabilityNotAdvertisedError` if the adapter does not back it.
3. Raise `UnknownActionError` if the capability has no such action.
4. Run `PaymentTokenGuard` if `arguments` has `:payment_token`. Run `Ap2::MandateGuard` if `arguments[:mandate]` is set.
5. Call the adapter. For `complete_checkout` only, the call is wrapped in a transaction-log reserve and commit, then `PolicyGuard.check!`, then the `Confirmer`. See [Security hooks](#security-hooks).
6. Run `PaymentEnrollmentGuard` on any `PaymentEnrollment` result.
7. Wrap the result. Objects with `to_wire_h` go through `WireEnvelope`. Arrays of such objects become an array payload.

`Mcp::Server.build` creates its `Dispatcher` with only `adapter:`, `registry:`, `logger:` and `journal:`. It does not forward `confirmer:`, `policy:`, `transaction_log:` or `order_ledger:`. A `complete_checkout` tool call therefore uses the default `Confirmer::Terminal`, which prompts on `$stdin`. That is the same stream a stdio MCP transport uses. To change these, build the `Dispatcher` yourself and call it from your own tools.

Over stdio, that default breaks every `complete_checkout` call:

- The prompt goes to `$stdout` with no newline, so it is glued to the front of the next JSON-RPC frame the server writes. The client can't parse that frame.
- The answer is read from `$stdin`, so the confirmer takes the client's next JSON-RPC frame as its answer, and the server never handles that frame. With no next frame, it waits 120 seconds.
- Anything but `y` denies, so the call fails with `ConfirmationDeniedError` and nothing is charged.

`Server.build` has no `confirmer:` option, so there is no way around this through it today.

Source: `portage-ucp/lib/portage/ucp/dispatcher.rb`

## MCP server

`Portage::Ucp::Mcp::Server.build` returns a `::MCP::Server` (from the `mcp` gem) named `portage-ucp`. It creates one tool per action of each advertised capability. The tool name is the action name, such as `search_catalog` or `create_checkout`. The description is `"<capability name>#<action>"`. Discount and fulfillment have no actions, so they add no tools.

| Method | Signature | Returns | Notes |
|---|---|---|---|
| `Mcp::Server.build` | `Mcp::Server.build(adapter:, registry: Portage::Ucp.configuration.registry, authenticator: Portage::Ucp.configuration.authenticator, rate_limiter: Portage::Ucp.configuration.rate_limiter, logger: Portage::Ucp.configuration.logger, journal: nil, **server_opts)` | `::MCP::Server` | `server_opts` go to `::MCP::Server.new`. `journal` is passed to `Dispatcher`. |

Each tool's input schema is built from the adapter method's keyword parameters. Required keywords (`keyreq`) become `required`. Property types are left unconstrained (`{}`).

A call counts as mutating when its adapter method takes `idempotency_key:`. Only mutating calls run the authenticator and the rate limiter. Read-only calls skip both, and `build` has no option to change that. If either rejects, the tool returns an error response with the exception message rather than raising.

`list_payment_methods` and `list_addresses` skip both by design. They take `oauth_token:` so the shopper's own token, not the authenticator, guards them (see [Portage extensions](#portage-extensions-appportage-ucp)).

`traceparent` in the request's `_meta` becomes the correlation id when it matches the W3C format. Otherwise a UUID is generated. `_meta["ucp-agent.profile"]` is passed through as `agent_profile`.

To run over stdio:

```ruby
server = Portage::Ucp::Mcp::Server.build(adapter: adapter)
MCP::Server::Transports::StdioTransport.new(server).open
```

`complete_checkout` can't succeed this way today. See the stdio note under [Dispatcher](#dispatcher).

For HTTP, mount the returned server with the `mcp` gem's own Rack or Streamable HTTP transport. That code lives in the `mcp` gem, not here. Wrap the mounted app in `Rack::SignatureVerification` if you want signed requests.

Source: `portage-ucp/lib/portage/ucp/mcp/server.rb`

## Security hooks

Nothing is permissive by default. See [security hooks](../security-hooks.md) for the overview.

| Hook | Signature | Behavior |
|---|---|---|
| `Authenticator` | `#call(server_context)` | Return any truthy auth context or raise `AuthenticationError`. Default `UnconfiguredAuthenticator` always raises. Any object that responds to `#call` works, including a lambda. |
| `RateLimiter` | `#check!(key, capability)` | Raise `RateLimitExceededError` to block. `key` is the raw MCP `server_context`. `capability` is the capability name. Default `NullRateLimiter` never blocks. |
| `PaymentTokenGuard` | `PaymentTokenGuard.validate!(token)` | Raises `RawPanRejectedError` if the token is 12 to 19 digits and passes the Luhn check. |
| `PaymentEnrollmentGuard` | `PaymentEnrollmentGuard.validate!(enrollment)` | Raises `InvalidPaymentEnrollmentError`. `pending` needs a `setup_url` and no `payment_token`. `complete` is the reverse. |
| `Ap2::MandateGuard` | `MandateGuard.validate!(mandate, trusted_keys: nil, require_signature: false)` | Raises `InvalidMandateError` for a missing field (`amount`, `currency`, `merchant`, `expires_at`, `signature`) or an expired mandate. With `trusted_keys`, it also verifies the signature through `Ap2::MandateSignature.verify!(mandate, trusted_keys:)`. With `require_signature: true` and no `trusted_keys`, it raises. |
| `Policy` | `Policy.load(path: Policy::PATH)`, `Policy.new(path:, data: {})` | Reads `~/.portage/policy.json`. Readers: `per_transaction_cap`, `rolling_cap`, `velocity`, `merchant_allowlist`, `token_scope(token_ref)`. |
| `PolicyGuard` | `PolicyGuard.check!(amount:, currency:, merchant:, token_ref:, policy:, transaction_log:)` | Returns `{ allowed: true }` or raises `PolicyViolationError`. Checks run in this order: spend cap, velocity, merchant allowlist, token scope. |
| `Confirmer::Terminal` | `new(timeout_seconds: 120, input: $stdin, output: $stdout)`, `#confirm!(amount:, currency:, merchant:, idempotency_key:)` | Prompts `[y/N]`. Anything but `y` raises `ConfirmationDeniedError`. |
| `Confirmer::AutoApprove` | `#confirm!(**)` | Always returns `{ approved: true }`. For specs only. |
| `Confirmer::Webhook` | `new(confirm_url:, status_url:, timeout_seconds: 900, poll_interval_seconds: 5, headers: {}, wait: nil)` | POSTs to `confirm_url`, then polls `status_url` or calls `wait`. Raises `ConfirmationDeniedError` on deny or timeout, and `Confirmer::WebhookApiError` if the HTTP call fails. |
| `Observability` | `Observability.log(logger, event, **fields)` | Writes one JSON line to `logger.info`. Replaces `payment_token`, `oauth_token`, `authorization`, `psp_reference` and common PII keys (email, name, address fields) with `[REDACTED]`. |
| `Security::Signature` | `Signature.verify!(method:, authority:, path:, headers:, body:, trusted_keys:, query: nil, required_components: %w[@method @authority @path idempotency-key], max_age: 300)` | Verifies an RFC 9421 HTTP Message Signature with a JWK set (ECDSA). Returns `{ verified: true, keyid: }` or raises a `Security::SignatureError` subclass. |
| `Rack::SignatureVerification` | `new(app, trusted_keys:, required_components: %w[@method @authority @path idempotency-key], max_age: 300, logger: Portage::Ucp.configuration.logger)` | Rack middleware. Verifies before the body is parsed and answers `401` with `{"error":"invalid_signature"}` on failure. |
| `Rack::WebhookEndpoint` | `new(secret:, on_order_event:, signature_header: "HTTP_X_UCP_SIGNATURE", logger:, trusted_proxies: [], passthrough_headers: [], passthrough_forwarded: "drop")` | POST only. Checks an HMAC-SHA256 hex digest of the raw body, then builds an `Order` from the JSON and calls `on_order_event.call(order)`. Responds 401, 400 or 200. |

`trusted_keys` for both signature classes is an array of JWK hashes or an object that responds to `#call`.

Other classes in this area, not covered here: `Support::TransactionLog` and `Support::OrderLedger` (each takes `store:`, `path:` and `clock:`), `Support::TokenRef`, `SchemaValidator`, `Resolver`, `Check`, and `Rack::ForwardedRequest`.

Source: `portage-ucp/lib/portage/ucp/authenticator.rb`, `portage-ucp/lib/portage/ucp/rate_limiter.rb`, `portage-ucp/lib/portage/ucp/payment_token_guard.rb`, `portage-ucp/lib/portage/ucp/payment_enrollment_guard.rb`, `portage-ucp/lib/portage/ucp/ap2/`, `portage-ucp/lib/portage/ucp/policy.rb`, `portage-ucp/lib/portage/ucp/policy_guard.rb`, `portage-ucp/lib/portage/ucp/confirmer.rb`, `portage-ucp/lib/portage/ucp/observability.rb`, `portage-ucp/lib/portage/ucp/security/`, `portage-ucp/lib/portage/ucp/rack/`

## Errors

All errors inherit from `Portage::Ucp::Error < StandardError`.

| Class | Raised when |
|---|---|
| `NotImplementedError` | An adapter method that was not overridden is called. |
| `UnknownCapabilityError` | `Dispatcher#call` gets a capability name the registry does not know. |
| `CapabilityNotAdvertisedError` | The capability exists but the adapter does not back it. |
| `UnknownActionError` | The capability has no such action. |
| `AuthenticationError` | An authenticator rejects a call. Raise it from your own authenticator. |
| `RateLimitExceededError` | A rate limiter blocks a call. Raise it from your own limiter. |
| `RawPanRejectedError` | `PaymentTokenGuard` finds a card-number-shaped token. |
| `InvalidPaymentEnrollmentError` | `PaymentEnrollmentGuard` rejects an enrollment result. |
| `InvalidMandateError` | `Ap2::MandateGuard` rejects a mandate. |
| `OutOfStockError` | Raise it from `complete_checkout` when a line item is unavailable. |
| `ConflictError` | Raise it when an upstream write collides (HTTP 409). `Support::Retry` never retries it. The caller should re-read and resubmit. |
| `UpstreamThrottledError` | `Support::Retry` ran out of backoff against an upstream throttle. This is distinct from `RateLimitExceededError`, which is Portage's own limiter. |
| `PolicyViolationError` | `PolicyGuard.check!` fails. Has `#reason` (a snake_case symbol) and `#decision`. |
| `ConfirmationDeniedError` | A `Confirmer` denies or times out. Has `#reason` and `#decision`. |
| `ProxyError` | A proxy hop fails. Has `#hop_index` (1-based) and `#status`. |
| `Security::SignatureError` | Base class of the signature errors below. |
| `Security::MissingSignatureError` | The signature headers are missing. |
| `Security::MalformedSignatureError` | The headers do not parse. |
| `Security::UnknownKeyError` | The `keyid` is not in the trusted set. |
| `Security::DigestMismatchError` | The body does not match the signed `content-digest`. |
| `Security::InvalidSignatureError` | The signature does not verify. |
| `Security::StaleSignatureError` | `created` is older than `max_age`. |
| `Support::ProxyConfig::ConfigError` | A proxy profile is invalid, such as an unknown mode or a protected header name. |

Source: `portage-ucp/lib/portage/ucp/errors.rb`, `portage-ucp/lib/portage/ucp/security/errors.rb`

## Idempotency and escalation

### Idempotency

Every mutating adapter method takes `idempotency_key:`. The adapter must return the same result for a repeated key. The core gem gives you a helper. Include `Portage::Ucp::Support::Idempotency` in your adapter and wrap the mutation in its private `dedup(idempotency_key) { ... }`.

| Piece | Signature | Notes |
|---|---|---|
| `Support::Idempotency#dedup` | `dedup(idempotency_key, &block)` | Private. Runs the block once per key, under a per-key lock. |
| `Support::Idempotency#idempotency_store=` | `idempotency_store=(store)` | Public. Set a store on one instance before its first `dedup`. |
| `Support::Idempotency::MemoryStore` | `MemoryStore.new` | Default. In process only. |
| `Support::Idempotency::FileStore` | `FileStore.new(path: File.join(Dir.home, ".portage", "idempotency.marshal"))` | For a single-host CLI. See the warning under [configuration](#loading-and-configuration). |

A custom store implements `fetch(key)`, `store(key, value)`, `fetch_or_store(key) { ... }` and `include?(key)`. Set it with `config.idempotency_provider` or `idempotency_store=`.

`Dispatcher` also uses the key for `complete_checkout`: it reserves a transaction record under that key before dispatch and settles it after. The call raises `KeyError` if `idempotency_key` is missing.

### Escalation

The checkout status `requires_escalation` means the store needs a human to finish the purchase. Your adapter sets it on the `Checkout` it returns. Core does not change it.

`Support::Escalation.reason(checkout_status:, warnings: [])` returns `:requires_escalation` if the status is `"requires_escalation"`, `:mismatch` if `warnings` is non-empty, or `nil`. The store's own status wins over a mismatch. `Support::Escalation::STATUS` is the string `"requires_escalation"`.

Source: `portage-ucp/lib/portage/ucp/support/idempotency.rb`, `portage-ucp/lib/portage/ucp/support/idempotency/`, `portage-ucp/lib/portage/ucp/support/escalation.rb`

## Support::Connection and ProxyConfig

`Support::Connection` is the one shared seam for outbound HTTP. It replaces raw `Net::HTTP.start` calls. For usage and configuration, see [proxy support](../proxy.md).

| Method | Signature | Returns | Notes |
|---|---|---|---|
| `Support::Connection.start` | `start(uri, route:, proxy: ProxyConfig.current, open_timeout: nil, read_timeout: nil, &block)` | the block's value | Yields an object that answers `#request`, `#get` and `#post`. Timeouts default to 60 seconds. Raises `ProxyError` on a hop failure. |
| `Support::Connection.redact` | `redact(uri)` | `String` | Host and port with credentials masked. |
| `Support::ProxyConfig.new` | `ProxyConfig.new(profiles: {}, routes: {}, no_proxy: [])` | config | |
| `Support::ProxyConfig.current` | `ProxyConfig.current` | config | Process-wide default. Direct until you set it. |
| `Support::ProxyConfig.current=` | `ProxyConfig.current = config` | | |
| `Support::ProxyConfig#chain_for` | `chain_for(route, host:)` | `Array<Profile>` | |
| `Support::ProxyConfig::Profile.new` | `Profile.new(mode: :forward, url: nil, proxy_headers: {}, ca_file: nil, target_header: nil, target_param: nil)` | profile | `mode` is `:direct`, `:forward` or `:gateway`. |

`Support::HttpClient` (used by the bundled adapters) builds on `Connection`. Its defaults are a 5 second open timeout and a 30 second read timeout.

Source: `portage-ucp/lib/portage/ucp/support/connection.rb`, `portage-ucp/lib/portage/ucp/support/proxy_config.rb`, `portage-ucp/lib/portage/ucp/support/http_client.rb`

## End-to-end example

A minimal in-memory catalog and cart adapter. It overrides catalog and cart methods only, so the manifest advertises `dev.ucp.shopping.catalog` and `dev.ucp.shopping.cart` and nothing else.

```ruby
require "portage/ucp"

class TinyAdapter < Portage::Ucp::Adapter
  include Portage::Ucp::Support::Idempotency

  PRODUCT = Portage::Ucp::Product.new(
    id: "sku-1",
    title: "Brass wall light",
    description: Portage::Ucp::Description.new(plain: "Handmade brass wall light."),
    price_range: Portage::Ucp::PriceRange.new(
      min: Portage::Ucp::Price.new(amount: 12_000, currency: "GBP"),
      max: Portage::Ucp::Price.new(amount: 12_000, currency: "GBP")
    ),
    variants: [
      Portage::Ucp::Variant.new(
        id: "sku-1-v1", title: "Default",
        description: Portage::Ucp::Description.new(plain: "Default variant"),
        price: Portage::Ucp::Price.new(amount: 12_000, currency: "GBP")
      )
    ]
  )

  def initialize
    super
    @carts = {}
  end

  def search_catalog(query:, limit:)
    matches = [PRODUCT].select { |p| p.title.downcase.include?(query.downcase) }.first(limit)
    Portage::Ucp::CatalogSearchResult.new(products: matches)
  end

  def get_product(product_id:)
    product_id == PRODUCT.id ? Portage::Ucp::ProductDetail.new(product: PRODUCT) : nil
  end

  def create_cart(line_items:, idempotency_key:, discount_codes: nil)
    dedup(idempotency_key) do
      id = "cart-#{@carts.size + 1}"
      @carts[id] = build_cart(id, line_items)
    end
  end

  def get_cart(cart_id:) = @carts.fetch(cart_id)

  private

  def build_cart(id, line_items)
    lines = line_items.each_with_index.map do |line, index|
      item = Portage::Ucp::Item.new(id: line[:product_id], title: PRODUCT.title, price: 12_000)
      total = 12_000 * line[:quantity]
      Portage::Ucp::LineItem.new(
        id: "line-#{index + 1}", item: item, quantity: line[:quantity],
        totals: [Portage::Ucp::Total.new(type: "subtotal", amount: total)]
      )
    end
    sum = lines.sum { |l| l.totals.first.amount }
    Portage::Ucp::Cart.new(
      id: id, line_items: lines, currency: "GBP",
      totals: [Portage::Ucp::Total.new(type: "total", amount: sum)]
    )
  end
end

Portage::Ucp.configure do |config|
  config.authenticator = lambda { |server_context|
    # Return a truthy value to allow, or raise Portage::Ucp::AuthenticationError.
    server_context || raise(Portage::Ucp::AuthenticationError, "unauthenticated")
  }
  config.business = { name: "Example Store", url: "https://shop.example" }
  config.services = [{ transport: "mcp", endpoint: "https://shop.example/mcp" }]
end

adapter = TinyAdapter.new

# Discovery document (mount at /.well-known/ucp in a config.ru):
manifest = Portage::Ucp::Manifest.new(adapter: adapter)
puts manifest.to_h[:ucp][:capabilities].keys
# => ["dev.ucp.shopping.catalog", "dev.ucp.shopping.cart"]

# MCP server over stdio:
server = Portage::Ucp::Mcp::Server.build(adapter: adapter)
MCP::Server::Transports::StdioTransport.new(server).open
```

The `Cart#totals` type names (`"subtotal"`, `"total"`) are free-form strings in this gem. Use whatever your UCP schema expects. `SchemaValidator` checks wire output against the vendored UCP schemas, and the RSpec conformance kit (`require "portage/ucp/rspec"`, then `it_behaves_like "a portage adapter"`) checks the behavioral guarantees. See [writing adapters](../writing-adapters.md).

Source: `portage-ucp/lib/portage/ucp/reference_adapter.rb` (a complete adapter to copy from)
