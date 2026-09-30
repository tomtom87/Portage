require "portage/ucp"

module Portage
  module Cli
    module Index
      # A ProductStore entry as the persisted subset of a UCP Product wire
      # hash (docs/plans/local-catalogue.md Phase 3), for `index search`'s
      # `product` field. Built only from what the index keeps, so it has no
      # id, description, price_range or availability: the index never stores
      # a price or stock, and a missing field is left out rather than faked.
      # The live Product comes from `find`.
      module EntryProduct
        TAXONOMY = "google_product_category".freeze

        module_function

        # @param entry [Hash] a ProductStore entry.
        # @return [Hash] string-keyed, UCP Product shaped.
        def wire(entry)
          wire = { "title" => entry["title"], "handle" => entry["handle"], "url" => entry["url"],
                   "media" => media(entry["image_url"]), "options" => entry["options"],
                   "variants" => Array(entry["variant_ids"]).map { |id| { "id" => id } },
                   "categories" => category(entry["category"]) }
          wire.reject { |_field, value| value.nil? || value == [] }
        end

        def media(url)
          url.to_s.empty? ? nil : [Portage::Ucp::Media.new(type: "image", url: url).to_wire_h]
        end

        def category(id)
          id.to_s.empty? ? nil : [Portage::Ucp::Category.new(value: id, taxonomy: TAXONOMY).to_wire_h]
        end
      end
    end
  end
end
