module Portage
  module Ucp
    module Client
      module Support
        # Small in-memory Adapter for exercising Client.for_adapter's loopback
        # transport end to end — search a product, create a checkout, complete
        # it — without needing a real backend or subprocess.
        class FakeAdapter < Portage::Ucp::Adapter
          def initialize
            super
            @products = {}
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

          def create_checkout(line_items:, idempotency_key:)
            dedup(idempotency_key) { build_checkout(next_id("chk"), line_items, status: "ready_for_complete") }
          end

          def get_checkout(checkout_id:)
            @checkouts[checkout_id]
          end

          def complete_checkout(checkout_id:, payment_token:, idempotency_key:)
            dedup(idempotency_key) do
              checkout = @checkouts.fetch(checkout_id)
              @checkouts[checkout_id] = Portage::Ucp::Checkout.new(**checkout.to_h, status: "completed")
            end
          end

          private

          def build_checkout(id, requested_line_items, status:)
            line_items = requested_line_items.map { |req| build_line_item(req) }
            subtotal = line_items.sum { |li| li.totals.find { |t| t.type == "total" }.amount }
            @checkouts[id] = Portage::Ucp::Checkout.new(
              id: id, status: status, line_items: line_items, currency: "USD",
              totals: totals_for(subtotal), links: []
            )
          end

          def build_line_item(req)
            product = @products.fetch(req[:product_id])
            total = product.price.amount_minor * req[:quantity]
            Portage::Ucp::LineItem.new(
              id: next_id("li"),
              item: Portage::Ucp::Item.new(id: product.id, title: product.title, price: product.price.amount_minor),
              quantity: req[:quantity], totals: totals_for(total)
            )
          end

          def totals_for(amount)
            [Portage::Ucp::Total.new(type: "subtotal", amount: amount),
             Portage::Ucp::Total.new(type: "total", amount: amount)]
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
end
