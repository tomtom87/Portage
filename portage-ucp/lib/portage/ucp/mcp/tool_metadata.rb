module Portage
  module Ucp
    module Mcp
      # Per-action tool metadata — description, parameter descriptions, and
      # MCP annotations — for Server.build_tool to attach to each generated
      # ::MCP::Tool. Kept separate from Capability (name/version/actions/
      # schema — the UCP wire contract) since this is MCP-presentation only:
      # what a calling agent reads before it decides whether and how to call
      # a tool, not part of the UCP spec itself. Content mirrors the @param/
      # @return docs already on Adapter's methods (adapter.rb) rather than
      # inventing anything new.
      module ToolMetadata
        ID = "A stable identifier returned by an earlier call (e.g. get_cart, create_checkout) " \
             "— not something the caller makes up.".freeze
        IDEMPOTENCY_KEY = "Caller-generated key that dedupes retries: calling again with the same " \
                          "key returns the original result instead of repeating the effect.".freeze
        REPLACE_NOTE = "Replaces the existing contents rather than adding to them — resend the " \
                       "full desired list with an item adjusted, added, or omitted.".freeze

        # JSON Schema `type` for parameter names whose shape is unambiguous
        # from the name alone and constant across every action it appears
        # in; left out entirely (no `type`) where it genuinely varies.
        PARAM_TYPES = {
          "query" => "string", "limit" => "integer", "product_id" => "string",
          "product_ids" => "array", "cart_id" => "string", "checkout_id" => "string",
          "order_id" => "string", "idempotency_key" => "string", "payment_token" => "string",
          "reason" => "string", "line_items" => "array", "discount_codes" => "array",
          "fulfillment" => "object", "mandate" => "object"
        }.freeze

        TOOLS = {
          "search_catalog" => {
            description: "Search the store's product catalog by free-text query, returning up to " \
                         "`limit` matches with price and availability. Use this to discover products " \
                         "when you don't yet have an ID; once you do, use get_product for one or " \
                         "lookup_catalog for several — neither re-runs a search.",
            params: { "query" => "Free-text search query.", "limit" => "Maximum number of results to return." },
            annotations: { read_only_hint: true, destructive_hint: false, idempotent_hint: true }
          },
          "get_product" => {
            description: "Fetch full details — price, availability, and whatever else the store's " \
                         "catalog carries — for one product by ID. Returns not-found rather than " \
                         "raising if the ID doesn't exist. Use search_catalog first if you don't " \
                         "already have the ID; use lookup_catalog instead for several known IDs, to " \
                         "avoid one call per product.",
            params: { "product_id" => "Product ID, as returned by search_catalog or lookup_catalog." },
            annotations: { read_only_hint: true, destructive_hint: false, idempotent_hint: true }
          },
          "lookup_catalog" => {
            description: "Batch-fetch several products by ID in one call, same result shape as " \
                         "search_catalog. Use when you already have a set of product IDs — e.g. " \
                         "hydrating a cart or order — instead of calling get_product once per ID.",
            params: { "product_ids" => "Product IDs to fetch, as returned by search_catalog, a cart, or an order." },
            annotations: { read_only_hint: true, destructive_hint: false, idempotent_hint: true }
          },
          "create_cart" => {
            description: "Start a new cart from a list of line items — the cart's complete starting " \
                         "contents, not an item appended to an existing one. Use update_cart to change " \
                         "a cart that already exists. Optional discount_codes applies coupons if the " \
                         "store supports them.",
            params: {
              "line_items" => "Items to add, each {product_id:, quantity:}.",
              "idempotency_key" => IDEMPOTENCY_KEY,
              "discount_codes" => "Discount/coupon codes to apply, if the store supports them."
            },
            annotations: { read_only_hint: false, destructive_hint: false, idempotent_hint: true }
          },
          "get_cart" => {
            description: "Fetch a cart's current contents and totals by ID.",
            params: { "cart_id" => ID },
            annotations: { read_only_hint: true, destructive_hint: false, idempotent_hint: true }
          },
          "update_cart" => {
            description: "Replace a cart's contents. #{REPLACE_NOTE} Use this for every change to an " \
                         "existing cart: adding an item, removing one, or changing a quantity.",
            params: {
              "cart_id" => ID,
              "line_items" => "The cart's complete desired contents, each {product_id:, quantity:}. #{REPLACE_NOTE}",
              "idempotency_key" => IDEMPOTENCY_KEY,
              "discount_codes" => "Discount/coupon codes to apply, if the store supports them."
            },
            annotations: { read_only_hint: false, destructive_hint: false, idempotent_hint: true }
          },
          "cancel_cart" => {
            description: "Cancel and discard a cart. Irreversible — use this to abandon a cart the " \
                         "shopper no longer wants.",
            params: { "cart_id" => ID, "idempotency_key" => IDEMPOTENCY_KEY },
            annotations: { read_only_hint: false, destructive_hint: true, idempotent_hint: true }
          },
          "create_checkout" => {
            description: "Start a checkout directly from line items, skipping a separate cart. " \
                         "Optional discount_codes applies coupons; optional fulfillment carries the " \
                         "shopper's desired shipping or pickup selection, if the store supports it. " \
                         "Does not charge anything — call complete_checkout once the shopper approves " \
                         "the total from get_checkout.",
            params: {
              "line_items" => "Items to buy, each {product_id:, quantity:}.",
              "idempotency_key" => IDEMPOTENCY_KEY,
              "discount_codes" => "Discount/coupon codes to apply, if the store supports them.",
              "fulfillment" => "Desired shipping/pickup method selection, if the store supports it."
            },
            annotations: { read_only_hint: false, destructive_hint: false, idempotent_hint: true }
          },
          "get_checkout" => {
            description: "Fetch a checkout's current contents, totals, and status by ID.",
            params: { "checkout_id" => ID },
            annotations: { read_only_hint: true, destructive_hint: false, idempotent_hint: true }
          },
          "update_checkout" => {
            description: "Replace a checkout's contents before payment. #{REPLACE_NOTE} Also accepts " \
                         "updated discount_codes or fulfillment selection. Does not charge anything.",
            params: {
              "checkout_id" => ID,
              "line_items" => "The checkout's complete desired contents, each {product_id:, quantity:}. " \
                              "#{REPLACE_NOTE}",
              "idempotency_key" => IDEMPOTENCY_KEY,
              "discount_codes" => "Discount/coupon codes to apply, if the store supports them.",
              "fulfillment" => "Desired shipping/pickup method selection, if the store supports it."
            },
            annotations: { read_only_hint: false, destructive_hint: false, idempotent_hint: true }
          },
          "complete_checkout" => {
            description: "Charge the checkout and place the order — the one tool here that moves " \
                         "money. Takes a single-use payment_token from a payment handler, never a raw " \
                         "card number. Re-checks stock at this point, since catalog calls don't " \
                         "guarantee live inventory, and fails rather than charging if a line item is " \
                         "no longer available. Only call this after the shopper has explicitly " \
                         "approved the exact total from get_checkout.",
            params: {
              "checkout_id" => ID,
              "payment_token" => "Single-use payment token from a payment handler — never a raw card number.",
              "idempotency_key" => IDEMPOTENCY_KEY,
              "mandate" => "Optional AP2 payment mandate authorizing this charge, alongside or instead " \
                           "of payment_token."
            },
            annotations: { read_only_hint: false, destructive_hint: true, idempotent_hint: true }
          },
          "cancel_checkout" => {
            description: "Cancel a checkout before payment. Irreversible — use this to abandon a " \
                         "checkout the shopper no longer wants. Safe with respect to money, since " \
                         "complete_checkout hasn't run yet.",
            params: { "checkout_id" => ID, "idempotency_key" => IDEMPOTENCY_KEY },
            annotations: { read_only_hint: false, destructive_hint: true, idempotent_hint: true }
          },
          "get_order" => {
            description: "Fetch a placed order's status, line items, and totals by ID. Returns " \
                         "not-found rather than raising if the ID doesn't exist.",
            params: { "order_id" => ID },
            annotations: { read_only_hint: true, destructive_hint: false, idempotent_hint: true }
          },
          "cancel_order" => {
            description: "Cancel an already-placed order. Irreversible. Optional reason is a " \
                         "free-text note for the merchant, not a fixed enum.",
            params: {
              "order_id" => ID, "idempotency_key" => IDEMPOTENCY_KEY,
              "reason" => "Optional free-text reason for the cancellation."
            },
            annotations: { read_only_hint: false, destructive_hint: true, idempotent_hint: true }
          },
          "request_return" => {
            description: "Request a return for one or more order line items. This files the request; " \
                         "it doesn't refund money itself — the order shows the items as pending until " \
                         "the merchant processes it. Use refund_order only once a refund has actually " \
                         "been approved.",
            params: {
              "order_id" => ID,
              "line_items" => "Items to return, each {id:, quantity:}.",
              "idempotency_key" => IDEMPOTENCY_KEY,
              "reason" => "Optional free-text reason for the return."
            },
            annotations: { read_only_hint: false, destructive_hint: false, idempotent_hint: true }
          },
          "refund_order" => {
            description: "Refund one or more order line items, moving money back to the shopper. " \
                         "Irreversible. Use request_return first if the merchant requires a return " \
                         "before refunding.",
            params: {
              "order_id" => ID,
              "line_items" => "Items to refund, each {id:, quantity:}.",
              "idempotency_key" => IDEMPOTENCY_KEY,
              "reason" => "Optional free-text reason for the refund."
            },
            annotations: { read_only_hint: false, destructive_hint: true, idempotent_hint: true }
          }
        }.freeze
      end
    end
  end
end
