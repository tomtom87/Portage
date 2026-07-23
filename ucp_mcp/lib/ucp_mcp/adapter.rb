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
    # @return [UcpMcp::Cart]
    def get_cart(cart_id:) = not_implemented
    # @return [UcpMcp::Cart]
    def add_line_item(cart_id:, product_id:, quantity:, idempotency_key:) = not_implemented
    # @return [UcpMcp::Cart]
    def remove_line_item(cart_id:, line_item_id:, idempotency_key:) = not_implemented

    # --- Checkout (dev.ucp.shopping.checkout) ---
    # @return [UcpMcp::Checkout]
    def create_checkout(line_items:, idempotency_key:) = not_implemented
    # @return [UcpMcp::Checkout]
    def update_checkout(checkout_id:, updates:, idempotency_key:) = not_implemented
    # @param payment_token [String] single-use token from a UCP payment handler / AP2
    #   exchange — NEVER a raw PAN.
    # @return [UcpMcp::Checkout]
    def complete_checkout(checkout_id:, payment_token:, idempotency_key:) = not_implemented

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
