require "json"
require "uri"

module Portage
  module Ucp
    module Instagram
      # Generic Portage::Ucp::Adapter over Meta's Graph API Commerce Catalog
      # — no merchant-specific business logic, same posture as the other
      # adapters in this project.
      #
      # IMPORTANT: like Portage::Ucp::Etsy::Adapter, this is deliberately a
      # **catalog + redirect-link checkout + order** adapter, not a full
      # transactional one — and for a more fundamental reason than Etsy.
      # Instagram/Facebook Shops split into two populations:
      #
      # - "Checkout on your website" catalogs: each product carries its own
      #   merchant-hosted `url`. Buying happens entirely on the merchant's
      #   own site, not through Meta at all — this is the case this
      #   adapter's `create_checkout` is built for, redirecting to that
      #   `url` per product, same posture as Etsy's listing-page redirect.
      # - "Checkout on Instagram/Facebook" catalogs: buying happens
      #   natively inside the Meta app, with **no exposed URL or API to
      #   drive it** at all — not even a redirect is possible here. Meta
      #   orders from *this* population are the only ones `get_order` can
      #   ever see (see Portage::Ucp::Instagram::Mapper.order's comment);
      #   this adapter can't originate a purchase for them, only read one
      #   back after the fact.
      #
      # Same as Etsy: doesn't override `get_cart`/`create_cart`/
      # `update_cart`/`cancel_cart` (no cart resource exists),
      # `update_checkout`/`complete_checkout`/`cancel_checkout` (nothing to
      # update/complete/cancel programmatically — calling them raises
      # Portage::Ucp::NotImplementedError), or `link_identity` (Instagram/
      # Facebook user login is a separate concern from the Page/catalog
      # token used here). `create_checkout`'s Checkout objects are **not
      # real Meta resources** — they live only in this Adapter instance's
      # memory, same as Etsy's.
      class Adapter < Portage::Ucp::Adapter
        PRODUCT_FIELDS = "id,name,description,price,availability,url,item_group_id".freeze

        def initialize(client:, catalog_id:)
          super()
          @client = client
          @catalog_id = catalog_id
          # §9a: mutating Adapter methods must dedup by idempotency_key so
          # an agent's retry on a dropped connection doesn't build a second,
          # different in-memory Checkout for the same intent.
          @idempotency_results = {}
          @checkouts = {}
        end

        def search_catalog(query:, limit:)
          filter = URI.encode_www_form_component(JSON.generate(name: { i_contains: query }))
          data = @client.get("/#{@catalog_id}/products?fields=#{PRODUCT_FIELDS}&limit=#{limit}&filter=#{filter}")
          (data["data"] || []).map { |node| Mapper.product(node) }
        end

        def get_product(product_id:)
          node = @client.get("/#{product_id}?fields=#{PRODUCT_FIELDS}")
          return nil unless node["id"]

          Mapper.product(with_variants(node))
        rescue Portage::Ucp::Instagram::ApiError => e
          raise unless [400, 404].include?(e.status)

          nil
        end

        def create_checkout(line_items:, idempotency_key:)
          dedup(idempotency_key) do
            products = line_items.map { |li| product_with_quantity(li) }
            checkout_id = "instagram-checkout-#{idempotency_key}"
            checkout = Mapper.checkout(products, id: checkout_id, status: "incomplete")
            @checkouts[checkout_id] = checkout
            checkout
          end
        end

        def get_checkout(checkout_id:)
          @checkouts[checkout_id]
        end

        # See the class-level comment: this only ever returns data for
        # "Checkout on Instagram/Facebook" merchants — everyone else's
        # orders live entirely outside Meta's system.
        def get_order(order_id:)
          fields = "id,order_status,items{retailer_id,product_name,quantity,price_per_unit}," \
                   "estimated_payment_details"
          node = @client.get("/#{order_id}?fields=#{fields}")
          node["id"] ? Mapper.order(node) : nil
        rescue Portage::Ucp::Instagram::ApiError => e
          raise unless [400, 403, 404].include?(e.status)

          nil
        end

        private

        # A product's own resource only carries its `item_group_id`, not
        # its siblings — fetching the rest of the variant group is a second
        # call, only made for #get_product's single-product path, same N+1
        # reasoning as every other adapter's variant fetch.
        def with_variants(node)
          return node unless node["item_group_id"]

          filter = URI.encode_www_form_component(JSON.generate(item_group_id: { eq: node["item_group_id"] }))
          data = @client.get("/#{@catalog_id}/products?fields=id,name,availability,price&filter=#{filter}")
          node.merge("variants_detail" => data["data"])
        end

        def product_with_quantity(line_item)
          @client.get("/#{line_item[:product_id]}?fields=id,name,price,url").merge("quantity" => line_item[:quantity])
        end

        def dedup(idempotency_key)
          return @idempotency_results[idempotency_key] if @idempotency_results.key?(idempotency_key)

          @idempotency_results[idempotency_key] = yield
        end
      end
    end
  end
end
