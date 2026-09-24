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

        # Safety cap on Adapter#search_catalog's pagination — a malformed or
        # unbounded `paging.next` chain (or a `limit` far bigger than a
        # reasonable single search) can't turn one search into an unbounded
        # crawl of Meta's API.
        MAX_PAGES = 10

        # §9a dedup via Support::Idempotency, so an agent's retry on a
        # dropped connection doesn't build a second, different in-memory
        # Checkout for the same intent.
        include Portage::Ucp::Support::Idempotency

        # See README's "Meta is sunsetting native checkout": Graph API drops
        # Commerce Order Management entirely, across every version, on
        # 2026-10-27. `#get_order` keeps working until then and warns once
        # per process rather than once per call, same reasoning as Ruby's own
        # `Kernel#warn`-based deprecations — a long-lived MCP server calling
        # this per request would otherwise spam stderr forever.
        ORDER_DEPRECATION_NOTICE =
          "Portage::Ucp::Instagram::Adapter#get_order is deprecated: Meta removes Commerce Order Management " \
          "endpoints (the Graph API this method calls) across all API versions on 2026-10-27, sunsetting native " \
          "Checkout on Instagram/Facebook. This adapter becomes catalog + checkout-handoff only after that date " \
          "— see README.md/CHANGELOG.md.".freeze

        def initialize(client:, catalog_id:)
          super()
          @client = client
          @catalog_id = catalog_id
          @checkouts = {}
          @order_deprecation_warned = false
        end

        def search_catalog(query:, limit:)
          filter = URI.encode_www_form_component(JSON.generate(name: { i_contains: query }))
          path = "/#{@catalog_id}/products?fields=#{PRODUCT_FIELDS}&limit=#{limit}&filter=#{filter}"
          Portage::Ucp::CatalogSearchResult.new(products: paginated_products(path, limit))
        end

        def get_product(product_id:)
          node = @client.get("/#{product_id}?fields=#{PRODUCT_FIELDS}")
          return nil unless node["id"]

          Portage::Ucp::ProductDetail.new(product: Mapper.product(with_variants(node)))
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
          warn_order_deprecation
          fields = "id,order_status,items{retailer_id,product_name,quantity,price_per_unit}," \
                   "estimated_payment_details"
          node = @client.get("/#{order_id}?fields=#{fields}")
          node["id"] ? Mapper.order(node) : nil
        rescue Portage::Ucp::Instagram::ApiError => e
          raise unless [400, 403, 404].include?(e.status)

          nil
        end

        private

        def warn_order_deprecation
          return if @order_deprecation_warned

          @order_deprecation_warned = true
          Kernel.warn(ORDER_DEPRECATION_NOTICE)
        end

        # Follows Meta's cursor pagination — each page's `paging.next` is
        # already a complete URL built from that page's `paging.cursors.
        # after` — collecting products until `limit` is reached or the API
        # runs out of pages (no `paging.next`), capped at MAX_PAGES requests
        # either way.
        def paginated_products(path, limit)
          products = []
          pages = 0

          while path && products.length < limit && pages < MAX_PAGES
            data = @client.get(path)
            nodes = data["data"]
            products.concat(nodes.is_a?(Array) ? nodes.map { |node| Mapper.product(node) } : [])
            path = next_page(data)
            pages += 1
          end

          products.first(limit)
        end

        # `data["paging"]` is occasionally absent (last page) or, for a
        # malformed response, not even a Hash — guarded the same way as
        # every other Mapper/Adapter read of a Meta response body here.
        def next_page(data)
          paging = data["paging"]
          paging.is_a?(Hash) ? paging["next"] : nil
        end

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
      end
    end
  end
end
