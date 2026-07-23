module UcpMcp
  module Support
    # In-memory reference Adapter — proves the protocol layer without a real backend.
    # Demonstrates correct idempotency-key dedup: mutating calls MUST return the
    # original result for a repeated key rather than re-running the mutation.
    class FakeAdapter < UcpMcp::Adapter
      def initialize
        @products = {}
        @carts = {}
        @checkouts = {}
        @idempotency_results = {}
        @next_id = 0
      end

      def seed_product(product)
        @products[product.id] = product
      end

      def search_catalog(query:, limit:)
        @products.values.select { |p| p.title.downcase.include?(query.downcase) }.first(limit)
      end

      def get_product(product_id:)
        @products[product_id]
      end

      def get_cart(cart_id:)
        @carts[cart_id]
      end

      def add_line_item(cart_id:, product_id:, quantity:, idempotency_key:)
        dedup(idempotency_key) do
          cart = @carts[cart_id] || UcpMcp::Cart.new(id: cart_id, line_items: [],
                                                      subtotal: UcpMcp::Money.new(amount_minor: 0, currency: "USD"),
                                                      currency: "USD")
          product = @products.fetch(product_id)
          unit_price = product.price
          total = UcpMcp::Money.new(amount_minor: unit_price.amount_minor * quantity, currency: unit_price.currency)
          line_item = UcpMcp::LineItem.new(id: next_id("li"), product_id: product_id,
                                            quantity: quantity, unit_price: unit_price, total: total)
          new_subtotal = UcpMcp::Money.new(
            amount_minor: cart.subtotal.amount_minor + total.amount_minor, currency: cart.currency
          )
          @carts[cart_id] = UcpMcp::Cart.new(id: cart_id, line_items: cart.line_items + [line_item],
                                              subtotal: new_subtotal, currency: cart.currency)
        end
      end

      def remove_line_item(cart_id:, line_item_id:, idempotency_key:)
        dedup(idempotency_key) do
          cart = @carts.fetch(cart_id)
          removed, remaining = cart.line_items.partition { |li| li.id == line_item_id }
          removed_total = removed.sum { |li| li.total.amount_minor }
          new_subtotal = UcpMcp::Money.new(amount_minor: cart.subtotal.amount_minor - removed_total, currency: cart.currency)
          @carts[cart_id] = UcpMcp::Cart.new(id: cart_id, line_items: remaining, subtotal: new_subtotal, currency: cart.currency)
        end
      end

      def create_checkout(line_items:, idempotency_key:)
        dedup(idempotency_key) do
          zero = UcpMcp::Money.new(amount_minor: 0, currency: "USD")
          subtotal = UcpMcp::Money.new(amount_minor: line_items.sum { |li| li.total.amount_minor }, currency: "USD")
          @checkouts[next_id("chk")] = nil
          id = @checkouts.keys.last
          @checkouts[id] = UcpMcp::Checkout.new(id: id, status: "pending", line_items: line_items,
                                                 subtotal: subtotal, tax: zero, total: subtotal,
                                                 currency: "USD", locale: "en-US", available_payment_handlers: [])
        end
      end

      def complete_checkout(checkout_id:, payment_token:, idempotency_key:)
        dedup(idempotency_key) do
          checkout = @checkouts.fetch(checkout_id)
          @checkouts[checkout_id] = UcpMcp::Checkout.new(**checkout.to_h.merge(status: "completed"))
        end
      end

      private

      def dedup(idempotency_key)
        return @idempotency_results[idempotency_key] if @idempotency_results.key?(idempotency_key)

        @idempotency_results[idempotency_key] = yield
      end

      def next_id(prefix)
        @next_id += 1
        "#{prefix}_#{@next_id}"
      end
    end
  end
end
