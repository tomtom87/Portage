require_relative "ucp/version"
require_relative "ucp/configuration"
require_relative "ucp/errors"
require_relative "ucp/value_objects"
require_relative "ucp/wire_envelope"
require_relative "ucp/adapter"
# Shared building blocks for adapter gems (Portage::Ucp::Support) — nothing in
# the core gem's own request path uses them, they exist so the bundled
# Shopify/Wix/WooCommerce/... gems don't each re-derive the same money
# conversion, dedup table and HTTP plumbing.
require_relative "ucp/support/amounts"
require_relative "ucp/support/totals"
require_relative "ucp/support/line_item_status"
require_relative "ucp/support/idempotency"
require_relative "ucp/support/checkout_state"
require_relative "ucp/support/api_error"
require_relative "ucp/support/not_found"
require_relative "ucp/support/http_client"
require_relative "ucp/support/token_exchange"
require_relative "ucp/payment_token_guard"
require_relative "ucp/authenticator"
require_relative "ucp/rate_limiter"
require_relative "ucp/observability"
require_relative "ucp/capability"
require_relative "ucp/manifest"
require_relative "ucp/schema_validator"
require_relative "ucp/capabilities/catalog"
require_relative "ucp/capabilities/cart"
require_relative "ucp/capabilities/checkout"
require_relative "ucp/capabilities/order"
require_relative "ucp/capabilities/identity_linking"
require_relative "ucp/capability_registry"
require_relative "ucp/capability_negotiator"
require_relative "ucp/dispatcher"
require_relative "ucp/mcp/server"
require_relative "ucp/rack/manifest_endpoint"
require_relative "ucp/rack/webhook_endpoint"
require_relative "ucp/resolver"
require_relative "ucp/check"

module Portage
  module Ucp
  end
end
