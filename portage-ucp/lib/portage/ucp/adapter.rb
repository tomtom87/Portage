module Portage
  module Ucp
    # @abstract Subclass and override the methods for the capabilities you support.
    #   Unoverridden methods leave that capability out of the manifest.
    class Adapter
      # --- Catalog (dev.ucp.shopping.catalog) ---
      # @return [Portage::Ucp::CatalogSearchResult]
      def search_catalog(query:, limit:) = not_implemented
      # nil when the product isn't found, same not-found posture as
      # get_cart/get_checkout/get_order.
      # @return [Portage::Ucp::ProductDetail, nil]
      def get_product(product_id:) = not_implemented

      # --- Cart (dev.ucp.shopping.cart) ---
      # Full-replacement semantics, matching UCP's real cart methods: create/
      # update take the complete desired line_items list, not a single item.
      # `line_items:` is an array of request-shaped hashes (e.g.
      # `{product_id:, quantity:}`) — the adapter looks up product data and
      # builds the response's Item/Total/LineItem itself.
      # @return [Portage::Ucp::Cart]
      def get_cart(cart_id:) = not_implemented
      # `discount_codes:` is the dev.ucp.shopping.discount extension — nil
      # (the default) means the request didn't touch discounts at all; an
      # adapter that doesn't override #discount_codes_supported? never sees
      # anything but nil here (see below). Full-replacement like line_items:
      # once codes are involved, [] clears them, same as UCP's own
      # discounts_object semantics.
      # @return [Portage::Ucp::Cart]
      def create_cart(line_items:, idempotency_key:, discount_codes: nil) = not_implemented
      # @return [Portage::Ucp::Cart]
      def update_cart(cart_id:, line_items:, idempotency_key:, discount_codes: nil) = not_implemented
      # @return [Portage::Ucp::Cart]
      def cancel_cart(cart_id:, idempotency_key:) = not_implemented

      # --- Checkout (dev.ucp.shopping.checkout) ---
      # `discount_codes:` carries the same dev.ucp.shopping.discount
      # semantics as create_cart/update_cart above.
      # `fulfillment:` is the dev.ucp.shopping.fulfillment extension — nil
      # (the default) means the request didn't touch fulfillment at all; an
      # adapter that doesn't override #fulfillment_supported? never sees
      # anything but nil here (see below). On create it carries the agent's
      # desired methods (type + line_item_ids per shipping/pickup group —
      # `Portage::Ucp::FulfillmentMethod#id`/`#destinations`/`#groups` are
      # omitted since the merchant generates those); on update it carries the
      # agent's `selected_destination_id`/`selected_option_id` choices against
      # the methods/groups the merchant already returned.
      # @return [Portage::Ucp::Checkout]
      def create_checkout(line_items:, idempotency_key:, discount_codes: nil, fulfillment: nil) = not_implemented
      # @return [Portage::Ucp::Checkout]
      def get_checkout(checkout_id:) = not_implemented

      # Full-replacement, same as update_cart — line_items is required on
      # checkout update per the real spec.
      # @return [Portage::Ucp::Checkout]
      def update_checkout(checkout_id:, line_items:, idempotency_key:, discount_codes: nil, fulfillment: nil)
        not_implemented
      end

      # @param payment_token [String] single-use token from a UCP payment handler / AP2
      #   exchange — NEVER a raw PAN.
      # Re-checks stock at the point of committing money, since search_catalog/
      # get_product (dev.ucp.shopping.catalog) don't promise live inventory and
      # nothing else re-checks between browsing and buying. An adapter whose
      # platform rejects completion because a line item is out of stock or
      # otherwise unavailable should raise Portage::Ucp::OutOfStockError rather
      # than a generic/platform error, so callers can distinguish a stale-stock
      # failure from e.g. a declined payment.
      # @raise [Portage::Ucp::OutOfStockError] if a line item is no longer available
      # @return [Portage::Ucp::Checkout]
      def complete_checkout(checkout_id:, payment_token:, idempotency_key:) = not_implemented
      # @return [Portage::Ucp::Checkout]
      def cancel_checkout(checkout_id:, idempotency_key:) = not_implemented

      # --- Order (dev.ucp.shopping.order) ---
      # @return [Portage::Ucp::Order, nil]
      def get_order(order_id:) = not_implemented
      # Cancels a placed order. `reason` is an optional human-readable note,
      # not a closed enum — the platform-specific enum mapping (if any) is an
      # adapter concern.
      # @return [Portage::Ucp::Order]
      def cancel_order(order_id:, idempotency_key:, reason: nil) = not_implemented
      # Requests a return for one or more order line items. `line_items` is an
      # array of request-shaped hashes (`{id:, quantity:}`, unsigned) — same
      # request/response asymmetry as `create_cart`'s `line_items:`. A return
      # is a request the merchant still has to process; it shows up as a
      # `pending` `Portage::Ucp::Adjustment` until they do.
      # @return [Portage::Ucp::Order]
      def request_return(order_id:, line_items:, idempotency_key:, reason: nil) = not_implemented
      # Refunds one or more order line items.
      # @return [Portage::Ucp::Order]
      def refund_order(order_id:, line_items:, idempotency_key:, reason: nil) = not_implemented

      # --- Discount (dev.ucp.shopping.discount) ---
      # Extends Cart/Checkout with the `discount_codes:` param above rather
      # than adding actions of its own — Capability::DISCOUNT advertises off
      # this predicate instead of an overridden action method, since there's
      # no dedicated method for #advertised_for? to detect an override on.
      # @return [Boolean]
      def discount_codes_supported? = false

      # --- Fulfillment (dev.ucp.shopping.fulfillment) ---
      # Extends Checkout with the `fulfillment:` param above rather than
      # adding actions of its own — Capability::FULFILLMENT advertises off
      # this predicate instead of an overridden action method, same rationale
      # as #discount_codes_supported? above.
      # @return [Boolean]
      def fulfillment_supported? = false

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
