require "digest"

module Portage
  module Ucp
    # In-memory Adapter implementing every capability in the contract,
    # including dev.ucp.shopping.discount/fulfillment/identity — roadmap §8
    # step 1 called for one of these ("no real backend required to prove the
    # protocol layer works") and it never shipped; `spec/support/fake_adapter.rb`
    # filled that gap for the core gem's own specs, but stayed test-only,
    # catalog/cart/checkout/order only, and undocumented outside this repo.
    #
    # Two jobs: a copy-paste starting point for a third-party adapter author
    # (see README "Writing your own adapter"), and the fixture the
    # conformance kit (Portage::Ucp::RSpec, lib/portage/ucp/rspec.rb) runs its
    # own shared examples against to prove the kit itself is correct.
    #
    # Not a mock — every mutating action does the real bookkeeping (line-item
    # totals, checkout status transitions, order adjustments) an adapter over
    # a live platform would, just against an in-process Hash instead of an
    # HTTP API. `seed_product` is the one method with no `Adapter` contract
    # counterpart — there is no real backend to seed real data into.
    class ReferenceAdapter < Portage::Ucp::Adapter
      include Portage::Ucp::Support::Idempotency
      include Portage::Ucp::Support::CheckoutState

      # Products whose id starts with this prefix are treated as sold out —
      # #complete_checkout raises Portage::Ucp::OutOfStockError for them, the
      # same way a real adapter's stock re-check (Adapter#complete_checkout's
      # docs, design-log §16) would. Lets the conformance kit exercise that
      # path without depending on adapter-specific seed data.
      OUT_OF_STOCK_PREFIX = "oos_".freeze

      def initialize
        super
        @products = {}
        @carts = {}
        @checkouts = {}
        @orders = {}
        @identities = {}
        @next_id = 0
      end

      # Not part of the Adapter contract — this adapter has no backend to
      # seed real data into, so callers (a spec, a README example) hand it
      # catalog fixtures directly.
      def seed_product(product)
        @products[product.id] = product
      end

      def search_catalog(query:, limit:)
        matches = @products.values.select { |p| p.title.downcase.include?(query.downcase) }.first(limit)
        Portage::Ucp::CatalogSearchResult.new(products: matches)
      end

      def get_product(product_id:)
        product = @products[product_id]
        product && Portage::Ucp::ProductDetail.new(product: product)
      end

      def get_cart(cart_id:) = @carts[cart_id]

      def create_cart(line_items:, idempotency_key:, discount_codes: nil)
        dedup(idempotency_key) do
          id = next_id("cart")
          @carts[id] = build_cart(id, line_items, discount_codes)
        end
      end

      def update_cart(cart_id:, line_items:, idempotency_key:, discount_codes: nil)
        dedup(idempotency_key) do
          @carts[cart_id] = build_cart(cart_id, line_items, discount_codes, previous: @carts[cart_id])
        end
      end

      def cancel_cart(cart_id:, idempotency_key:)
        dedup(idempotency_key) do
          @carts.delete(cart_id)
          Portage::Ucp::Cart.new(id: cart_id, line_items: [], currency: "USD", totals: zero_totals)
        end
      end

      def create_checkout(line_items:, idempotency_key:, discount_codes: nil, fulfillment: nil)
        dedup(idempotency_key) do
          id = next_id("chk")
          record_checkout_status(id, "incomplete")
          @checkouts[id] = build_checkout(id, line_items, discount_codes, fulfillment, status: "incomplete")
        end
      end

      def get_checkout(checkout_id:) = @checkouts[checkout_id]

      def update_checkout(checkout_id:, line_items:, idempotency_key:, discount_codes: nil, fulfillment: nil)
        dedup(idempotency_key) do
          record_checkout_status(checkout_id, "incomplete")
          @checkouts[checkout_id] = build_checkout(checkout_id, line_items, discount_codes, fulfillment,
                                                   status: "incomplete", previous: @checkouts[checkout_id])
        end
      end

      # payment_token: is part of the Adapter contract's call signature (and
      # already validated as non-PAN by PaymentTokenGuard before this ever
      # runs, per §9) but this in-memory adapter has no payment processor to
      # pass it on to — nothing here should hold onto it any longer than the
      # single call needs to, so it's accepted and left unused rather than
      # stored (see .rubocop.yml's Lint/UnusedMethodArgument exclude, same
      # posture as the abstract Adapter#complete_checkout it overrides).
      def complete_checkout(checkout_id:, payment_token:, idempotency_key:)
        dedup(idempotency_key) do
          checkout = @checkouts.fetch(checkout_id)
          raise_if_any_line_out_of_stock!(checkout)

          order = store_order(checkout)
          confirmation = Portage::Ucp::OrderConfirmation.new(id: order.id, permalink_url: order.permalink_url)
          record_checkout_status(checkout_id, "completed")
          @checkouts[checkout_id] = Portage::Ucp::Checkout.new(**checkout.to_h, status: "completed",
                                                                                order: confirmation)
        end
      end

      def cancel_checkout(checkout_id:, idempotency_key:)
        dedup(idempotency_key) do
          record_checkout_status(checkout_id, "canceled")
          checkout = @checkouts.fetch(checkout_id)
          @checkouts[checkout_id] = Portage::Ucp::Checkout.new(**checkout.to_h, status: "canceled")
        end
      end

      def get_order(order_id:) = @orders[order_id]

      def cancel_order(order_id:, idempotency_key:, reason: nil)
        dedup(idempotency_key) do
          add_adjustment(order_id, type: "cancellation", status: "completed", description: reason)
        end
      end

      def request_return(order_id:, line_items:, idempotency_key:, reason: nil)
        dedup(idempotency_key) do
          add_adjustment(order_id, type: "return", status: "pending", line_items: line_items, description: reason)
        end
      end

      def refund_order(order_id:, line_items:, idempotency_key:, reason: nil)
        dedup(idempotency_key) do
          add_adjustment(order_id, type: "refund", status: "completed", line_items: line_items, description: reason)
        end
      end

      # Not memoized against @carts' own id sequence namespace collision:
      # next_id("cart") is shared with create_cart/update_cart, same as every
      # other *_id prefix here.
      def reorder(order_id:, idempotency_key:)
        dedup(idempotency_key) do
          order = @orders[order_id]
          next nil unless order

          available, unavailable = partition_reorderable(order.line_items)
          cart = build_cart(next_id("cart"), available, nil)
          @carts[cart.id] = cart
          Portage::Ucp::ReorderResult.new(cart: cart, unavailable_items: unavailable)
        end
      end

      def discount_codes_supported? = true
      def fulfillment_supported? = true

      # Accepts any non-blank token and mints a stable identity for it — real
      # OAuth verification is a platform concern this in-memory adapter has
      # no platform to defer to, same posture as PaymentTokenGuard drawing
      # the line at "rejects the clearest misuse" rather than proving
      # validity.
      def link_identity(oauth_token:)
        raise Portage::Ucp::AuthenticationError, "blank oauth_token" if oauth_token.to_s.empty?

        @identities[oauth_token] ||= Portage::Ucp::Identity.new(
          subject: "user_#{Digest::SHA256.hexdigest(oauth_token)[0, 12]}",
          email: nil, linked_at: Time.now.utc.iso8601
        )
      end

      private

      def add_adjustment(order_id, type:, status:, line_items: [], description: nil)
        order = @orders.fetch(order_id)
        adjustment = Portage::Ucp::Adjustment.new(
          id: next_id("adj"), type: type, occurred_at: Time.now.utc.iso8601, status: status,
          line_items: adjustment_line_items(line_items), totals: adjustment_totals(order, line_items),
          description: description
        )
        @orders[order_id] = Portage::Ucp::Order.new(**order.to_h, adjustments: order.adjustments + [adjustment])
      end

      def adjustment_line_items(line_items)
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

      def build_cart(id, requested_line_items, discount_codes, previous: nil)
        line_items = build_line_items(requested_line_items)
        discounts = discounts_for(discount_codes, previous&.discounts)
        Portage::Ucp::Cart.new(id: id, line_items: line_items, currency: "USD",
                               totals: totals_for(line_items, discounts), discounts: discounts)
      end

      def build_checkout(id, requested_line_items, discount_codes, fulfillment, status:, previous: nil)
        line_items = build_line_items(requested_line_items)
        discounts = discounts_for(discount_codes, previous&.discounts)
        Portage::Ucp::Checkout.new(
          id: id, status: status, line_items: line_items, currency: "USD",
          totals: totals_for(line_items, discounts), links: [], discounts: discounts,
          fulfillment: fulfillment || previous&.fulfillment || Portage::Ucp::CheckoutFulfillment.new
        )
      end

      # Fixed 10% off, applied only for the well-known code "SAVE10" — enough
      # for a conformance spec/adapter author to see a real AppliedDiscount
      # round-trip without inventing a discount engine this adapter has no
      # reason to model in full.
      def discounts_for(discount_codes, previous)
        return previous || Portage::Ucp::Discounts.new if discount_codes.nil?

        applied = if discount_codes.include?("SAVE10")
                    [Portage::Ucp::AppliedDiscount.new(title: "10% off",
                                                       amount: 0, code: "SAVE10")]
                  else
                    []
                  end
        Portage::Ucp::Discounts.new(codes: discount_codes, applied: applied)
      end

      # `req[:product_id]` is looked up against the featured (first) variant
      # — the same variant #search_catalog/#get_product would show as the
      # listing default — since this in-memory adapter's fixtures are
      # single-variant products and Item#id is spec'd as a variant id
      # (types/variant.json: "Used as item.id in checkout"), not a product
      # id.
      def build_line_items(requested)
        requested.map do |req|
          product = @products.fetch(req[:product_id])
          variant = product.variants.first
          total = variant.price.amount * req[:quantity]
          Portage::Ucp::LineItem.new(
            id: next_id("li"),
            item: Portage::Ucp::Item.new(id: variant.id, title: product.title, price: variant.price.amount),
            quantity: req[:quantity],
            totals: [Portage::Ucp::Total.new(type: "subtotal", amount: total),
                     Portage::Ucp::Total.new(type: "total", amount: total)]
          )
        end
      end

      def totals_for(line_items, discounts)
        subtotal = line_items.sum { |li| li.totals.find { |t| t.type == "total" }.amount }
        discount_amount = discounts.applied.sum(&:amount)
        [Portage::Ucp::Total.new(type: "subtotal", amount: subtotal),
         Portage::Ucp::Total.new(type: "total", amount: subtotal - discount_amount)]
      end

      def zero_totals
        [Portage::Ucp::Total.new(type: "subtotal", amount: 0), Portage::Ucp::Total.new(type: "total", amount: 0)]
      end

      # order.line_items here are the checkout's own response-shaped LineItem
      # objects (see #store_order) — item.id is a variant id, not the
      # product id build_cart's request-shaped hashes need (build_line_items'
      # note), so this re-derives product_id by scanning @products the same
      # way a real adapter would hit its platform's variant lookup.
      def partition_reorderable(line_items)
        available = []
        unavailable = []

        line_items.each do |line_item|
          product_id = product_id_for_variant(line_item.item.id)

          if product_id.nil?
            unavailable << unavailable_reorder_item(line_item, "discontinued")
          elsif line_item.item.id.start_with?(OUT_OF_STOCK_PREFIX)
            unavailable << unavailable_reorder_item(line_item, "out_of_stock")
          else
            available << { product_id: product_id, quantity: line_item.quantity }
          end
        end

        [available, unavailable]
      end

      def unavailable_reorder_item(line_item, reason)
        Portage::Ucp::UnavailableReorderItem.new(item_id: line_item.item.id, title: line_item.item.title,
                                                 reason: reason)
      end

      def product_id_for_variant(variant_id)
        @products.each_value do |product|
          return product.id if product.variants.any? { |variant| variant.id == variant_id }
        end
        nil
      end

      def raise_if_any_line_out_of_stock!(checkout)
        unavailable = checkout.line_items.select { |li| li.item.id.start_with?(OUT_OF_STOCK_PREFIX) }
        return if unavailable.empty?

        raise Portage::Ucp::OutOfStockError, "no longer available: #{unavailable.map { |li| li.item.title }.join(', ')}"
      end

      def next_id(prefix)
        @next_id += 1
        "#{prefix}_#{@next_id}"
      end
    end
  end
end
