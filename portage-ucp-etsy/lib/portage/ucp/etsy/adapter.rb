module Portage
  module Ucp
    module Etsy
      # Generic Portage::Ucp::Adapter over Etsy's Open API v3 — no
      # merchant-specific business logic, same posture as the other
      # adapters in this project.
      #
      # IMPORTANT: unlike Shopify/Wix/WooCommerce/BigCommerce/Magento, this
      # is deliberately a **catalog + redirect-link checkout + order**
      # adapter, not a full transactional one — Etsy's public API has no
      # cart, checkout, or add-to-cart endpoint at all. Buying only ever
      # happens on etsy.com itself. This adapter therefore:
      #
      # - Doesn't override `get_cart`/`create_cart`/`update_cart`/
      #   `cancel_cart` at all — `dev.ucp.shopping.cart` stays unadvertised.
      # - Overrides only `create_checkout`/`get_checkout`. `Checkout#links`
      #   carries one link per requested listing, pointing straight at that
      #   listing's own etsy.com page — the closest real equivalent to
      #   "add this to your cart and check out" this API allows. `update_
      #   checkout`/`complete_checkout`/`cancel_checkout` are left
      #   unoverridden on purpose: there's nothing to update or complete
      #   programmatically, and calling them raises
      #   Portage::Ucp::NotImplementedError rather than silently pretending
      #   to do something. `dev.ucp.shopping.checkout` still gets advertised
      #   (Capability#advertised_for? only needs one overridden method), so
      #   an agent sees the capability and can discover which actions are
      #   actually backed by trying them.
      # - The Checkout objects `create_checkout` returns are **not real
      #   Etsy resources** — nothing on Etsy's side tracks them. They live
      #   only in this Adapter instance's memory (`get_checkout` reads back
      #   what `create_checkout` stored), so they don't survive a process
      #   restart or a different Adapter instance.
      # - `get_order`'s `checkout_id` is always blank — there's no real
      #   checkout for a receipt to link back to in the first place (see
      #   above), a more fundamental gap than WooCommerce/Magento needing
      #   adapter-side tracking for a *real* checkout.
      #
      # Deliberately doesn't override `link_identity` either — Etsy buyer/
      # seller OAuth identity is a separate concern from the shop-owner
      # access_token this gem uses for catalog/order reads.
      class Adapter < Portage::Ucp::Adapter
        def initialize(client:, shop_id:)
          super()
          @client = client
          @shop_id = shop_id
          # §9a: mutating Adapter methods must dedup by idempotency_key so
          # an agent's retry on a dropped connection doesn't build a second,
          # different in-memory Checkout for the same intent.
          @idempotency_results = {}
          @checkouts = {}
        end

        # Etsy's shop-listings endpoint supports no keyword filter at all
        # (only limit/offset/sort) — this fetches a page of active listings
        # and filters by title client-side, so it's a much weaker "search"
        # than every other adapter's real server-side query. Fine for a
        # small shop, misleading for a large one.
        def search_catalog(query:, limit:)
          data = @client.get("/shops/#{@shop_id}/listings/active?limit=100")
          matches = (data["results"] || []).select { |l| l["title"].to_s.downcase.include?(query.downcase) }
          matches.first(limit).map { |node| Mapper.product(node) }
        end

        def get_product(product_id:)
          node = @client.get("/listings/#{product_id}")
          return nil unless node["listing_id"]

          inventory = @client.get("/listings/#{product_id}/inventory")
          Mapper.product(node.merge("variants_detail" => inventory))
        rescue Portage::Ucp::Etsy::ApiError => e
          raise unless e.status == 404

          nil
        end

        def create_checkout(line_items:, idempotency_key:)
          dedup(idempotency_key) do
            listings = line_items.map { |li| listing_with_quantity(li) }
            checkout_id = "etsy-checkout-#{idempotency_key}"
            checkout = Mapper.checkout(listings, id: checkout_id, status: "incomplete")
            @checkouts[checkout_id] = checkout
            checkout
          end
        end

        def get_checkout(checkout_id:)
          @checkouts[checkout_id]
        end

        def get_order(order_id:)
          node = @client.get("/shops/#{@shop_id}/receipts/#{order_id}")
          node["receipt_id"] ? Mapper.order(node) : nil
        rescue Portage::Ucp::Etsy::ApiError => e
          raise unless e.status == 404

          nil
        end

        private

        def listing_with_quantity(line_item)
          @client.get("/listings/#{line_item[:product_id]}").merge("quantity" => line_item[:quantity])
        end

        def dedup(idempotency_key)
          return @idempotency_results[idempotency_key] if @idempotency_results.key?(idempotency_key)

          @idempotency_results[idempotency_key] = yield
        end
      end
    end
  end
end
