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

      def create_cart(line_items:, idempotency_key:)
        dedup(idempotency_key) do
          id = next_id("cart")
          @carts[id] = store_cart(id, line_items)
        end
      end

      def update_cart(cart_id:, line_items:, idempotency_key:)
        dedup(idempotency_key) { @carts[cart_id] = store_cart(cart_id, line_items) }
      end

      def cancel_cart(cart_id:, idempotency_key:)
        dedup(idempotency_key) do
          @carts.delete(cart_id)
          UcpMcp::Cart.new(id: cart_id, line_items: [], currency: "USD", totals: zero_totals)
        end
      end

      def create_checkout(line_items:, idempotency_key:)
        dedup(idempotency_key) do
          id = next_id("chk")
          @checkouts[id] = store_checkout(id, line_items, status: "incomplete")
        end
      end

      def get_checkout(checkout_id:)
        @checkouts[checkout_id]
      end

      def update_checkout(checkout_id:, line_items:, idempotency_key:)
        dedup(idempotency_key) do
          @checkouts[checkout_id] = store_checkout(checkout_id, line_items, status: "incomplete")
        end
      end

      def complete_checkout(checkout_id:, payment_token:, idempotency_key:)
        dedup(idempotency_key) do
          checkout = @checkouts.fetch(checkout_id)
          @checkouts[checkout_id] = UcpMcp::Checkout.new(**checkout.to_h, status: "completed")
        end
      end

      def cancel_checkout(checkout_id:, idempotency_key:)
        dedup(idempotency_key) do
          checkout = @checkouts.fetch(checkout_id)
          @checkouts[checkout_id] = UcpMcp::Checkout.new(**checkout.to_h, status: "canceled")
        end
      end

      private

      def store_cart(id, requested_line_items)
        line_items = build_line_items(requested_line_items)
        UcpMcp::Cart.new(id: id, line_items: line_items, currency: "USD", totals: totals_for(line_items))
      end

      def store_checkout(id, requested_line_items, status:)
        line_items = build_line_items(requested_line_items)
        UcpMcp::Checkout.new(id: id, status: status, line_items: line_items, currency: "USD",
                             totals: totals_for(line_items), links: [])
      end

      def build_line_items(requested)
        requested.map do |req|
          product = @products.fetch(req[:product_id])
          total = product.price.amount_minor * req[:quantity]
          UcpMcp::LineItem.new(
            id: next_id("li"),
            item: UcpMcp::Item.new(id: product.id, title: product.title, price: product.price.amount_minor),
            quantity: req[:quantity],
            totals: [UcpMcp::Total.new(type: "subtotal", amount: total),
                     UcpMcp::Total.new(type: "total", amount: total)]
          )
        end
      end

      def totals_for(line_items)
        subtotal = line_items.sum { |li| li.totals.find { |t| t.type == "total" }.amount }
        [UcpMcp::Total.new(type: "subtotal", amount: subtotal), UcpMcp::Total.new(type: "total", amount: subtotal)]
      end

      def zero_totals
        [UcpMcp::Total.new(type: "subtotal", amount: 0), UcpMcp::Total.new(type: "total", amount: 0)]
      end

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
