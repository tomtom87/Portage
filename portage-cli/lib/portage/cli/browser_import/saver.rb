require_relative "categorize"

module Portage
  module Cli
    module BrowserImport
      # Writes an approved Importer#plan into the user's own index — only
      # ever called after BrowserImport::Confirm said :save. A kept domain
      # becomes an Index::Store entry with `sources: ["history"]`/
      # `["bookmark"]`; one already in the index just gains those labels
      # and the new category weights (its capabilities and last_verified
      # are left for `index refresh` to re-check, same as Index::Builder's
      # #update_existing). A domain kept because the published
      # known-stores list already had it keeps that list's own
      # last_verified — this import never probed it. A kept product page becomes an
      # Index::ProductStore entry with the same `sources` labels, so
      # Index::Exporter never publishes it.
      class Saver
        def initialize(stores:, products:, now: Time.now)
          @stores = stores
          @products = products
          @now = now
        end

        # @return [Hash] stores:, products: — how many entries were written.
        def save(plan)
          kept = Array(plan[:kept])
          products = Array(plan[:products])
          kept.each { |entry| save_store(entry) }
          products.each { |product| save_product(product) }
          { stores: kept.length, products: products.length }
        end

        private

        def save_store(entry)
          existing = @stores.find(entry[:origin])
          fields = { sources: (Array(existing && existing["sources"]) + entry[:sources]).uniq,
                     categories: merge_categories(existing && existing["categories"], entry[:categories]) }
          fields.merge!(new_store_fields(entry)) unless existing
          @stores.upsert(entry[:origin], **fields)
        end

        def new_store_fields(entry)
          { platform: nil, capabilities: Array(entry[:capabilities]), webmcp_preset: entry[:webmcp_preset],
            last_verified: entry[:last_verified] || @now.to_i, handoff_only: entry[:handoff_only] ? true : false }
        end

        def merge_categories(existing, fresh)
          tally = Hash.new(0)
          [existing, fresh].each { |cats| Hash(cats).each { |id, weight| tally[id.to_s] += weight.to_i } }
          tally.sort_by { |_id, weight| -weight }.first(Categorize::TOP_CATEGORIES).to_h
        end

        def save_product(product)
          @products.upsert(product[:key], origin: product[:origin], seen_at: @now.to_i, title: product[:title],
                                          brand: nil, gtin: nil, category: product[:category],
                                          sources: [product[:source]])
        end
      end
    end
  end
end
