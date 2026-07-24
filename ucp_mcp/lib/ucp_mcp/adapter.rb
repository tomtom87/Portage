module UcpMcp
  # @abstract Subclass and override the methods for the capabilities you support.
  #   Unoverridden methods leave that capability out of the manifest.
  class Adapter
    # --- Catalog (dev.ucp.shopping.catalog) ---
    # @return [Array<UcpMcp::Product>]
    def search_catalog(query:, limit:) = not_implemented
    # @return [UcpMcp::Product, nil]
    def get_product(product_id:) = not_implemented

    # --- Cart (dev.ucp.shopping.cart) ---
    # Full-replacement semantics, matching UCP's real cart methods: create/
    # update take the complete desired line_items list, not a single item.
    # `line_items:` is an array of request-shaped hashes (e.g.
    # `{product_id:, quantity:}`) — the adapter looks up product data and
    # builds the response's Item/Total/LineItem itself.
    # @return [UcpMcp::Cart]
    def get_cart(cart_id:) = not_implemented
    # @return [UcpMcp::Cart]
    def create_cart(line_items:, idempotency_key:) = not_implemented
    # @return [UcpMcp::Cart]
    def update_cart(cart_id:, line_items:, idempotency_key:) = not_implemented
    # @return [UcpMcp::Cart]
    def cancel_cart(cart_id:, idempotency_key:) = not_implemented

    # --- Checkout (dev.ucp.shopping.checkout) ---
    # @return [UcpMcp::Checkout]
    def create_checkout(line_items:, idempotency_key:) = not_implemented
    # @return [UcpMcp::Checkout]
    def get_checkout(checkout_id:) = not_implemented
    # Full-replacement, same as update_cart — line_items is required on
    # checkout update per the real spec.
    # @return [UcpMcp::Checkout]
    def update_checkout(checkout_id:, line_items:, idempotency_key:) = not_implemented
    # @param payment_token [String] single-use token from a UCP payment handler / AP2
    #   exchange — NEVER a raw PAN.
    # @return [UcpMcp::Checkout]
    def complete_checkout(checkout_id:, payment_token:, idempotency_key:) = not_implemented
    # @return [UcpMcp::Checkout]
    def cancel_checkout(checkout_id:, idempotency_key:) = not_implemented

    # --- Order (dev.ucp.shopping.order) ---
    # @return [UcpMcp::Order, nil]
    def get_order(order_id:) = not_implemented

    # --- Identity Linking (dev.ucp.shopping.identity, OAuth 2.0) ---
    # @return [UcpMcp::Identity] linked profile for an exchanged OAuth token
    def link_identity(oauth_token:) = not_implemented

    private

    def not_implemented
      raise UcpMcp::NotImplementedError, "#{self.class} does not implement this capability"
    end
  end
end
