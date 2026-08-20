module Portage
  module Ucp
    module Support
      # In-memory reference Adapter — proves the protocol layer without a real backend.
      # Demonstrates correct idempotency-key dedup: mutating calls MUST return the
      # original result for a repeated key rather than re-running the mutation.
      class FakeAdapter < Portage::Ucp::Adapter
        def initialize
          @products = {}
          @carts = {}
          @checkouts = {}
          @orders = {}
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
            Portage::Ucp::Cart.new(id: cart_id, line_items: [], currency: "USD", totals: zero_totals)
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
            order = store_order(checkout)
            confirmation = Portage::Ucp::OrderConfirmation.new(id: order.id, permalink_url: order.permalink_url)
            @checkouts[checkout_id] = Portage::Ucp::Checkout.new(**checkout.to_h, status: "completed",
                                                                                  order: confirmation)
          end
        end

        def cancel_checkout(checkout_id:, idempotency_key:)
          dedup(idempotency_key) do
            checkout = @checkouts.fetch(checkout_id)
            @checkouts[checkout_id] = Portage::Ucp::Checkout.new(**checkout.to_h, status: "canceled")
          end
        end

        def get_order(order_id:)
          @orders[order_id]
        end

        def cancel_order(order_id:, idempotency_key:, reason: nil)
          dedup(idempotency_key) do
            add_adjustment(order_id, type: "cancellation", status: "completed", description: reason)
          end
        end

        def request_return(order_id:, line_items:, idempotency_key:, reason: nil)
          dedup(idempotency_key) do
            add_adjustment(order_id, type: "return", status: "pending", line_items: line_items,
                                     description: reason)
          end
        end

        def refund_order(order_id:, line_items:, idempotency_key:, reason: nil)
          dedup(idempotency_key) do
            add_adjustment(order_id, type: "refund", status: "completed", line_items: line_items,
                                     description: reason)
          end
        end

        private

        # Shared by cancel_order/request_return/refund_order: appends a new
        # Adjustment to the order's list and returns the updated order — same
        # resource as get_order, per the design-log's "extension, not a new
        # top-level family" call. `line_items:` (unsigned request shape) is
        # negated into the adjustment's signed quantity/amount per
        # types/adjustment.json's convention.
        def add_adjustment(order_id, type:, status:, line_items: [], description: nil)
          order = @orders.fetch(order_id)
          adjustment = Portage::Ucp::Adjustment.new(
            id: next_id("adj"), type: type, occurred_at: Time.now.utc.iso8601, status: status,
            line_items: adjustment_line_items(order, line_items),
            totals: adjustment_totals(order, line_items),
            description: description
          )
          @orders[order_id] = Portage::Ucp::Order.new(**order.to_h, adjustments: order.adjustments + [adjustment])
        end

        def adjustment_line_items(_order, line_items)
          return nil if line_items.empty?

          line_items.map { |li| { "id" => li[:id], "quantity" => -li[:quantity] } }
        end

        def adjustment_totals(order, line_items)
          return nil if line_items.empty?

          amount = line_items.sum do |li|
            order_line = order.line_items.find { |oli| oli.id == li[:id] }
            unit_price = order_line.totals.find { |t| t.type == "total" }.amount / order_line.quantity
            unit_price * li[:quantity]
          end
          [Portage::Ucp::Total.new(type: "total", amount: -amount)]
        end

        def store_order(checkout)
          id = next_id("ord")
          order = Portage::Ucp::Order.new(
            id: id, checkout_id: checkout.id, permalink_url: "https://example.com/orders/#{id}",
            line_items: checkout.line_items, fulfillment: Portage::Ucp::Fulfillment.new,
            currency: checkout.currency, totals: checkout.totals
          )
          @orders[id] = order
        end

        def store_cart(id, requested_line_items)
          line_items = build_line_items(requested_line_items)
          Portage::Ucp::Cart.new(id: id, line_items: line_items, currency: "USD", totals: totals_for(line_items))
        end

        def store_checkout(id, requested_line_items, status:)
          line_items = build_line_items(requested_line_items)
          Portage::Ucp::Checkout.new(id: id, status: status, line_items: line_items, currency: "USD",
                                     totals: totals_for(line_items), links: [])
        end

        def build_line_items(requested)
          requested.map do |req|
            product = @products.fetch(req[:product_id])
            total = product.price.amount_minor * req[:quantity]
            Portage::Ucp::LineItem.new(
              id: next_id("li"),
              item: Portage::Ucp::Item.new(id: product.id, title: product.title, price: product.price.amount_minor),
              quantity: req[:quantity],
              totals: [Portage::Ucp::Total.new(type: "subtotal", amount: total),
                       Portage::Ucp::Total.new(type: "total", amount: total)]
            )
          end
        end

        def totals_for(line_items)
          subtotal = line_items.sum { |li| li.totals.find { |t| t.type == "total" }.amount }
          [Portage::Ucp::Total.new(type: "subtotal", amount: subtotal),
           Portage::Ucp::Total.new(type: "total", amount: subtotal)]
        end

        def zero_totals
          [Portage::Ucp::Total.new(type: "subtotal", amount: 0), Portage::Ucp::Total.new(type: "total", amount: 0)]
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
end
