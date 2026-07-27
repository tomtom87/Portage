module Portage
  module Ucp
    # @abstract Subclass and override the methods for the capabilities you support.
    #   Unoverridden methods leave that capability out of the manifest.
    class Adapter
      # --- Catalog (dev.ucp.shopping.catalog) ---
      # @return [Array<Portage::Ucp::Product>]
      def search_catalog(query:, limit:) = not_implemented
      # @return [Portage::Ucp::Product, nil]
      def get_product(product_id:) = not_implemented

      # --- Cart (dev.ucp.shopping.cart) ---
      # Full-replacement semantics, matching UCP's real cart methods: create/
      # update take the complete desired line_items list, not a single item.
      # `line_items:` is an array of request-shaped hashes (e.g.
      # `{product_id:, quantity:}`) — the adapter looks up product data and
      # builds the response's Item/Total/LineItem itself.
      # @return [Portage::Ucp::Cart]
      def get_cart(cart_id:) = not_implemented
      # @return [Portage::Ucp::Cart]
      def create_cart(line_items:, idempotency_key:) = not_implemented
      # @return [Portage::Ucp::Cart]
      def update_cart(cart_id:, line_items:, idempotency_key:) = not_implemented
      # @return [Portage::Ucp::Cart]
      def cancel_cart(cart_id:, idempotency_key:) = not_implemented

      # --- Checkout (dev.ucp.shopping.checkout) ---
      # @return [Portage::Ucp::Checkout]
      def create_checkout(line_items:, idempotency_key:) = not_implemented
      # @return [Portage::Ucp::Checkout]
      def get_checkout(checkout_id:) = not_implemented
      # Full-replacement, same as update_cart — line_items is required on
      # checkout update per the real spec.
      # @return [Portage::Ucp::Checkout]
      def update_checkout(checkout_id:, line_items:, idempotency_key:) = not_implemented
      # @param payment_token [String] single-use token from a UCP payment handler / AP2
      #   exchange — NEVER a raw PAN.
      # @return [Portage::Ucp::Checkout]
      def complete_checkout(checkout_id:, payment_token:, idempotency_key:) = not_implemented
      # @return [Portage::Ucp::Checkout]
      def cancel_checkout(checkout_id:, idempotency_key:) = not_implemented

      # --- Order (dev.ucp.shopping.order) ---
      # @return [Portage::Ucp::Order, nil]
      def get_order(order_id:) = not_implemented

      # --- Identity Linking (dev.ucp.shopping.identity, OAuth 2.0) ---
      # @return [Portage::Ucp::Identity] linked profile for an exchanged OAuth token
      def link_identity(oauth_token:) = not_implemented

      private

      def not_implemented
        raise Portage::Ucp::NotImplementedError, "#{self.class} does not implement this capability"
      end
    end
  end
end
