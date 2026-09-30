require "portage/ucp"

require_relative "../../../classifier"

module Portage
  module Cli
    module Index
      module Sources
        class StorefrontProducts
          # One Shopify `/products.json` product -> Portage::Ucp::Product
          # (docs/plans/local-catalogue.md Phase 2), then the index sighting
          # taken from that Product. The product shape is UCP's, never a
          # parallel "card" vocabulary.
          #
          # Not portage-ucp-shopify's Mapper: that one reads Storefront
          # GraphQL nodes (camelCase, gids, MoneyV2 with a currency), not the
          # REST products.json shape, and portage-cli doesn't depend on that
          # gem.
          #
          # The Product carries what the store sent, price and availability
          # included (products.json has no currency, so Price#currency is
          # nil). #sighting is what the index persists, and it takes only
          # identity fields from the Product: price and availability never
          # reach it.
          module Mapper
            MAX_CATEGORIES = 3
            TAXONOMY = "google_product_category".freeze
            # Shopify's own placeholder for a product with no real options.
            PLACEHOLDER_OPTION = { "name" => "Title", "values" => ["Default Title"] }.freeze

            module_function

            # @param raw [Hash] one entry of products.json's "products".
            # @param classify [#call] text -> category ids (Classifier).
            def product(raw, origin:, classify: Classifier.method(:categories_for))
              options = product_options(raw)
              Portage::Ucp::Product.new(
                id: "gid://shopify/Product/#{raw['id']}", title: raw["title"].to_s,
                description: Portage::Ucp::Description.new(html: raw["body_html"]),
                price_range: price_range(raw), variants: Array(raw["variants"]).map { |v| variant(v, options) },
                handle: raw["handle"], url: "#{origin}/products/#{raw['handle']}",
                categories: categories(raw, classify), media: Array(raw["images"]).map { |i| media(i) },
                options: options.map { |o| option(o) }, tags: Array(raw["tags"])
              )
            end

            # @return [Hash] an Index::Builder sighting: the ProductStore
            #   fields plus `product:`, the extra entry fields this source
            #   adds (handle, url, image_url, options, variant_ids).
            def sighting(raw, origin:, classify: Classifier.method(:categories_for))
              product = product(raw, origin: origin, classify: classify)
              { origin: origin, url: product.url, title: product.title, brand: brand(raw), gtin: nil,
                categories: product.categories.select { |c| c.taxonomy == TAXONOMY }.map(&:value),
                product: { handle: product.handle, url: product.url, image_url: product.media.first&.url,
                           options: product.options.map(&:to_wire_h), variant_ids: product.variants.map(&:id) } }
            end

            def brand(raw)
              vendor = raw["vendor"].to_s.strip
              vendor.empty? ? nil : vendor
            end

            def product_options(raw)
              Array(raw["options"]).reject { |o| o.slice("name", "values") == PLACEHOLDER_OPTION }
            end

            def option(raw)
              values = Array(raw["values"]).map { |label| Portage::Ucp::OptionValue.new(label: label.to_s) }
              Portage::Ucp::ProductOption.new(name: raw["name"].to_s, values: values)
            end

            def variant(raw, options)
              Portage::Ucp::Variant.new(
                id: "gid://shopify/ProductVariant/#{raw['id']}", title: raw["title"].to_s,
                description: Portage::Ucp::Description.new(plain: raw["title"].to_s), price: price(raw["price"]),
                sku: raw["sku"].to_s.empty? ? nil : raw["sku"],
                list_price: raw["compare_at_price"] ? price(raw["compare_at_price"]) : nil,
                availability: raw.key?("available") ? { "available" => raw["available"] } : nil,
                options: selected_options(raw, options), media: variant_media(raw)
              )
            end

            # option1..option3 line up with the product's options by
            # position; the placeholder option is already gone, so a
            # "Default Title" variant selects nothing.
            def selected_options(raw, options)
              options.each_with_index.filter_map do |opt, i|
                label = raw["option#{i + 1}"]
                Portage::Ucp::SelectedOption.new(name: opt["name"].to_s, label: label.to_s) if label
              end
            end

            def variant_media(raw) = raw["featured_image"] ? [media(raw["featured_image"])] : []

            def media(raw)
              Portage::Ucp::Media.new(type: "image", url: raw["src"], alt_text: raw["alt"], width: raw["width"],
                                      height: raw["height"])
            end

            def price(amount)
              Portage::Ucp::Price.new(amount: Portage::Ucp::Support::Amounts.decimal_to_minor(amount), currency: nil)
            end

            def price_range(raw)
              amounts = Array(raw["variants"]).map { |v| v["price"] }.compact
              amounts = ["0"] if amounts.empty?
              minors = amounts.map { |a| Portage::Ucp::Support::Amounts.decimal_to_minor(a) }
              Portage::Ucp::PriceRange.new(min: Portage::Ucp::Price.new(amount: minors.min, currency: nil),
                                           max: Portage::Ucp::Price.new(amount: minors.max, currency: nil))
            end

            # Classifier on product_type and tags (the plan's inputs), top
            # three ids, then the store's own product_type as a merchant
            # category.
            def categories(raw, classify)
              text = [raw["product_type"], *Array(raw["tags"])].compact.join(" ")
              ids = text.strip.empty? ? [] : classify.call(text).first(MAX_CATEGORIES)
              google = ids.map { |id| Portage::Ucp::Category.new(value: id, taxonomy: TAXONOMY) }
              type = raw["product_type"].to_s.strip
              type.empty? ? google : google + [Portage::Ucp::Category.new(value: type, taxonomy: "merchant")]
            end
          end
        end
      end
    end
  end
end
