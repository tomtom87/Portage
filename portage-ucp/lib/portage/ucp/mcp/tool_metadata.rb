module Portage
  module Ucp
    module Mcp
      # Per-action tool metadata — description, parameter descriptions, and
      # MCP annotations — for Server.build_tool to attach to each generated
      # ::MCP::Tool. Kept separate from Capability (name/version/actions/
      # schema — the UCP wire contract) since this is MCP-presentation only:
      # what a calling agent reads before it decides whether and how to call
      # a tool, not part of the UCP spec itself. Written against the TDQS
      # rubric (tdqs.dev): purpose, when/when-not with named siblings,
      # behavior annotations can't carry, and return shape (no output schema).
      module ToolMetadata
        ID = "A stable identifier returned by an earlier call (e.g. get_cart, create_checkout) " \
             "— not something the caller makes up.".freeze
        IDEMPOTENCY_KEY = "Caller-generated key that dedupes retries: calling again with the same " \
                          "key returns the original result instead of repeating the effect.".freeze
        REPLACE_NOTE = "Replaces the existing contents rather than adding to them — resend the " \
                       "full desired list with an item adjusted, added, or omitted.".freeze
        AUTH_NOTE = "Requires an authenticated session and may be rate-limited; a rejected call " \
                    "returns an error result and changes nothing.".freeze
        OPEN_NOTE = "Needs no authentication and is never rate-limited.".freeze

        INSTRUCTIONS = "Shopping tools for one store, following the UCP lifecycle: catalog → cart → " \
                       "checkout → order. Find products with search_catalog, read them with " \
                       "get_product or lookup_catalog. Either build a cart (create_cart/update_cart) " \
                       "or go straight to create_checkout; a checkout never charges until " \
                       "complete_checkout, which must only follow the shopper's explicit approval of " \
                       "the exact total shown by get_checkout. After purchase, use get_order, " \
                       "cancel_order, request_return and refund_order. Catalog reads are open; every " \
                       "tool that changes state needs an authenticated session, and a server run " \
                       "without one is read-only. Payment is a single-use token, never a card number. " \
                       "Prices and stock come live from the store and can change between calls.".freeze

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
            description: "Search the store's product catalog by free-text query and return up to " \
                         "`limit` matching products, each with ID, title, price range, variants and " \
                         "availability. Use it to discover products when you have no product ID yet; " \
                         "once you have IDs, use get_product (one) or lookup_catalog (several) " \
                         "instead of searching again. #{OPEN_NOTE} An empty product list means no " \
                         "match, not an error; results reflect the live store and can change between calls.",
            params: {
              "query" => "Free-text search, e.g. a product name, brand or category (\"burton snowboard\").",
              "limit" => "Maximum number of products to return; 5–20 suits most searches."
            },
            annotations: { read_only_hint: true, destructive_hint: false, idempotent_hint: true }
          },
          "get_product" => {
            description: "Fetch the full record for one product by ID: title, description, price " \
                         "range, every variant with its own price and availability, URL and store " \
                         "policies. Use it when you need variant-level detail for a single product " \
                         "before adding it to a cart; use lookup_catalog for several IDs at once, and " \
                         "search_catalog if you don't have an ID. #{OPEN_NOTE} An unknown ID returns " \
                         "an empty result rather than an error.",
            params: { "product_id" => "Product ID, as returned by search_catalog or lookup_catalog." },
            annotations: { read_only_hint: true, destructive_hint: false, idempotent_hint: true }
          },
          "lookup_catalog" => {
            description: "Fetch several products by ID in one call, returning the same product list " \
                         "shape as search_catalog. Use it when you already hold a set of IDs — e.g. to " \
                         "refresh prices for a cart or order — instead of calling get_product once per " \
                         "ID; use search_catalog when you have a query rather than IDs. #{OPEN_NOTE} " \
                         "IDs the store doesn't recognise are omitted from the result, not reported as errors.",
            params: { "product_ids" => "Product IDs to fetch, as returned by search_catalog, a cart, or an order." },
            annotations: { read_only_hint: true, destructive_hint: false, idempotent_hint: true }
          },
          "create_cart" => {
            description: "Create a new cart holding the given line items and return it with its ID, " \
                         "line items, currency and totals. Use it to collect items before checkout; " \
                         "to change a cart that already exists use update_cart, and to buy straight " \
                         "away without a cart use create_checkout. Nothing is reserved or charged. " \
                         "#{AUTH_NOTE}",
            params: {
              "line_items" => "The cart's starting contents, each {product_id:, quantity:} with a " \
                              "product or variant ID from the catalog tools.",
              "idempotency_key" => IDEMPOTENCY_KEY,
              "discount_codes" => "Optional coupon codes to apply, if the store supports them."
            },
            annotations: { read_only_hint: false, destructive_hint: false, idempotent_hint: true }
          },
          "get_cart" => {
            description: "Fetch an existing cart by ID and return its line items, currency, applied " \
                         "discounts and current totals, recalculated against live store prices. Use " \
                         "it to show the shopper what is in the cart; it is for carts only — use " \
                         "get_checkout once a checkout exists and get_order after purchase. #{OPEN_NOTE}",
            params: { "cart_id" => "Cart ID returned by create_cart. #{ID}" },
            annotations: { read_only_hint: true, destructive_hint: false, idempotent_hint: true }
          },
          "update_cart" => {
            description: "Replace an existing cart's line items and discount codes, then return the " \
                         "updated cart with new totals. #{REPLACE_NOTE} Use it for every change to a " \
                         "cart — add, remove or change a quantity; use create_cart only for a new " \
                         "cart and update_checkout once the shopper has moved to checkout. " \
                         "Nothing is charged. #{AUTH_NOTE}",
            params: {
              "cart_id" => "Cart ID returned by create_cart. #{ID}",
              "line_items" => "The cart's complete desired contents, each {product_id:, quantity:}.",
              "idempotency_key" => IDEMPOTENCY_KEY,
              "discount_codes" => "Optional coupon codes, replacing those applied; leave out to keep the current ones."
            },
            annotations: { read_only_hint: false, destructive_hint: false, idempotent_hint: true }
          },
          "cancel_cart" => {
            description: "Abandon a cart and return it in its final state; don't reuse the cart ID " \
                         "afterwards (some stores delete it, others such as Shopify let it expire). " \
                         "Use it when the shopper gives up on the cart; to just " \
                         "remove items use update_cart instead, and to abandon a checkout use " \
                         "cancel_checkout. No money is involved. #{AUTH_NOTE}",
            params: { "cart_id" => "Cart ID returned by create_cart. #{ID}", "idempotency_key" => IDEMPOTENCY_KEY },
            annotations: { read_only_hint: false, destructive_hint: true, idempotent_hint: true }
          },
          "create_checkout" => {
            description: "Open a checkout for the given line items and return it with its ID, status, " \
                         "currency, itemised totals (including tax and shipping once known) and links. " \
                         "Use it when the shopper is ready to buy; use create_cart instead if they " \
                         "are still collecting items. Does not charge — complete_checkout does that, " \
                         "only after the shopper approves the total. #{AUTH_NOTE}",
            params: {
              "line_items" => "Items to buy, each {product_id:, quantity:} with a product or variant ID " \
                              "from the catalog tools or a cart.",
              "idempotency_key" => IDEMPOTENCY_KEY,
              "discount_codes" => "Optional coupon codes to apply, if the store supports them.",
              "fulfillment" => "Optional shipping or pickup selection; leave it out to get the " \
                               "store's available options back on the checkout."
            },
            annotations: { read_only_hint: false, destructive_hint: false, idempotent_hint: true }
          },
          "get_checkout" => {
            description: "Fetch an existing checkout by ID and return its status, line items, " \
                         "currency and itemised totals. Use it to show the shopper the exact final " \
                         "total to approve before complete_checkout, or to check whether a completed " \
                         "checkout produced an order; use get_cart for carts and get_order for placed " \
                         "orders. #{OPEN_NOTE}",
            params: { "checkout_id" => "Checkout ID returned by create_checkout. #{ID}" },
            annotations: { read_only_hint: true, destructive_hint: false, idempotent_hint: true }
          },
          "update_checkout" => {
            description: "Replace an open checkout's line items, discount codes or fulfillment " \
                         "selection and return it with recalculated totals. #{REPLACE_NOTE} Use it " \
                         "before payment only; a completed checkout can't change — adjust the order " \
                         "with cancel_order or request_return instead. Does not charge, and any total " \
                         "the shopper approved earlier must be re-approved. #{AUTH_NOTE}",
            params: {
              "checkout_id" => "Checkout ID returned by create_checkout. #{ID}",
              "line_items" => "The checkout's complete desired contents, each {product_id:, quantity:}.",
              "idempotency_key" => IDEMPOTENCY_KEY,
              "discount_codes" => "Optional coupon codes, replacing those applied; leave out to keep the current ones.",
              "fulfillment" => "Optional shipping or pickup selection, from the options listed on the checkout."
            },
            annotations: { read_only_hint: false, destructive_hint: false, idempotent_hint: true }
          },
          "complete_checkout" => {
            description: "Charge the shopper and place the order for an open checkout — the only tool " \
                         "here that spends money. Call it once, only after the shopper has explicitly " \
                         "approved the exact total from get_checkout; never to preview a price. Before " \
                         "charging it rejects anything resembling a raw card number, enforces the " \
                         "operator's spending caps and allowlist, may require a human confirmation, " \
                         "and re-checks stock, failing without a charge if anything is off. Returns " \
                         "the checkout with status completed and the new order. #{AUTH_NOTE}",
            params: {
              "checkout_id" => "Checkout ID returned by create_checkout. #{ID}",
              "payment_token" => "Single-use payment token from a payment handler — never a raw card number.",
              "idempotency_key" => "#{IDEMPOTENCY_KEY} Reuse it on retry so a timeout never charges twice.",
              "mandate" => "Optional AP2 payment mandate authorizing this charge, alongside or instead " \
                           "of payment_token; its signature is verified before use."
            },
            annotations: { read_only_hint: false, destructive_hint: true, idempotent_hint: true }
          },
          "cancel_checkout" => {
            description: "Abandon an open checkout before payment and return it with status canceled; " \
                         "it cannot be completed afterwards. Use it when the shopper declines the " \
                         "total; nothing has been charged yet, so no refund is needed. For a checkout " \
                         "that already completed, use cancel_order instead. #{AUTH_NOTE}",
            params: { "checkout_id" => "Checkout ID returned by create_checkout. #{ID}",
                      "idempotency_key" => IDEMPOTENCY_KEY },
            annotations: { read_only_hint: false, destructive_hint: true, idempotent_hint: true }
          },
          "get_order" => {
            description: "Fetch a placed order by ID and return its line items with per-item " \
                         "fulfillment status, shipping details, totals, permalink and any " \
                         "cancellations, returns or refunds applied so far. Use it to answer " \
                         "\"where is my order\" or to pick line item IDs for request_return or " \
                         "refund_order; use get_checkout for anything not yet paid. #{OPEN_NOTE} " \
                         "An unknown ID returns an empty result rather than an error.",
            params: { "order_id" => "Order ID from a completed checkout. #{ID}" },
            annotations: { read_only_hint: true, destructive_hint: false, idempotent_hint: true }
          },
          "cancel_order" => {
            description: "Cancel an entire placed order and return it with the cancellation recorded. " \
                         "Use it before the order ships; for part of an order, or once it has shipped, " \
                         "use request_return. Whether a refund follows automatically depends on the " \
                         "store — check the returned order's adjustments. Cannot be undone. #{AUTH_NOTE}",
            params: {
              "order_id" => "Order ID from a completed checkout. #{ID}", "idempotency_key" => IDEMPOTENCY_KEY,
              "reason" => "Optional free-text note for the merchant, e.g. \"ordered by mistake\"."
            },
            annotations: { read_only_hint: false, destructive_hint: true, idempotent_hint: true }
          },
          "request_return" => {
            description: "File a return request for some or all line items of a placed order and " \
                         "return the order with the request recorded as pending. It only asks — no " \
                         "money moves until the merchant approves and a refund is issued with " \
                         "refund_order. Use it for delivered items; use cancel_order for an order " \
                         "that hasn't shipped. #{AUTH_NOTE}",
            params: {
              "order_id" => "Order ID from a completed checkout. #{ID}",
              "line_items" => "Items to return, each {id:, quantity:} using the order line item IDs from get_order.",
              "idempotency_key" => IDEMPOTENCY_KEY,
              "reason" => "Optional free-text reason for the merchant, e.g. \"wrong size\"."
            },
            annotations: { read_only_hint: false, destructive_hint: false, idempotent_hint: true }
          },
          "refund_order" => {
            description: "Refund some or all line items of a placed order back to the original " \
                         "payment method and return the order with the refund recorded. Money moves " \
                         "and it cannot be reversed. Use it once a refund is agreed; if the store " \
                         "needs the goods back first, call request_return before this. To call off " \
                         "a whole unshipped order, use cancel_order. #{AUTH_NOTE}",
            params: {
              "order_id" => "Order ID from a completed checkout. #{ID}",
              "line_items" => "Items to refund, each {id:, quantity:} using the order line item IDs from get_order.",
              "idempotency_key" => IDEMPOTENCY_KEY,
              "reason" => "Optional free-text reason for the merchant."
            },
            annotations: { read_only_hint: false, destructive_hint: true, idempotent_hint: true }
          }
        }.freeze
      end
    end
  end
end
