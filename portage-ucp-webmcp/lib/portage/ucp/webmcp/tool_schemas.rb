module Portage
  module Ucp
    module WebMcp
      # What ToolCatalog adds on top of Mcp::Server's generated tools/list for
      # a browser-native agent: a readable description per standard action,
      # and typed JSON Schemas for the parameters Mcp::Server can only name
      # (it derives properties from keyword names alone, so each is `{}`).
      module ToolSchemas
        DESCRIPTIONS = {
          "search_catalog" => "Search the store's catalog by free-text query.",
          "get_product" => "Fetch one product, with its variants, prices and availability.",
          "lookup_catalog" => "Fetch several products by id in one call.",
          "create_cart" => "Create a cart from line items ({ product_id, quantity }).",
          "get_cart" => "Fetch a cart by id.",
          "update_cart" => "Replace a cart's line items.",
          "cancel_cart" => "Discard a cart.",
          "create_checkout" => "Start a checkout from line items. Check the returned status: " \
                               "requires_escalation means the shopper must finish at links[].",
          "get_checkout" => "Fetch a checkout by id.",
          "update_checkout" => "Replace a checkout's line items or fulfillment selection.",
          "complete_checkout" => "Place the order for a ready checkout with a tokenized payment credential. " \
                                 "Never pass a raw card number.",
          "cancel_checkout" => "Abandon a checkout.",
          "get_order" => "Fetch an order by id.",
          "cancel_order" => "Cancel an order.",
          "request_return" => "Request a return for line items on an order.",
          "refund_order" => "Refund line items on an order."
        }.freeze

        STRING = { "type" => "string" }.freeze
        LINE_ITEMS = {
          "type" => "array", "minItems" => 1,
          "items" => { "type" => "object", "required" => %w[product_id quantity],
                       "properties" => { "product_id" => STRING,
                                         "quantity" => { "type" => "integer", "minimum" => 1 } } }
        }.freeze

        # Only used where the generated schema left a property as `{}` (it
        # always does today — Mcp::Server derives properties from keyword
        # names alone).
        PARAMETER_SCHEMAS = {
          "query" => STRING, "limit" => { "type" => "integer", "minimum" => 1 },
          "product_id" => STRING, "product_ids" => { "type" => "array", "items" => STRING },
          "cart_id" => STRING, "checkout_id" => STRING, "order_id" => STRING, "reason" => STRING,
          "line_items" => LINE_ITEMS, "discount_codes" => { "type" => "array", "items" => STRING },
          "payment_token" => STRING.merge("description" => "Tokenized payment credential — never a raw PAN."),
          "idempotency_key" => STRING.merge("description" => "Optional; generated per call when omitted.")
        }.freeze
      end
    end
  end
end
