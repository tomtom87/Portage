require "spec_helper"

RSpec.describe Portage::Ucp::Shopify::Queries do
  after do
    Portage::Ucp::Shopify.instance_variable_set(:@configuration, nil)
  end

  describe ".product_fields" do
    it "omits both metafields fragments when nothing is configured" do
      expect(described_class.product_fields).not_to include("metafields(identifiers:")
    end

    it "splices a product-scoped metafields fragment built from the configured identifiers" do
      Portage::Ucp::Shopify.configure { |c| c.metadata_field(:color_hex, metafield: "custom.color_code") }

      expect(described_class.product_fields)
        .to include('metafields(identifiers: [{namespace: "custom", key: "color_code"}]) { key namespace value type }')
    end

    it "splices a variant-scoped fragment inside the variants selection, independent of product scope" do
      Portage::Ucp::Shopify.configure do |c|
        c.metadata_field(:color_hex, metafield: "custom.color_code", scope: :variant)
      end

      fields = described_class.product_fields
      variants_block = fields[fields.index("variants(first:")..]

      expect(variants_block).to include('metafields(identifiers: [{namespace: "custom", key: "color_code"}])')
      expect(fields[0...fields.index("variants(first:")]).not_to include("metafields(identifiers:")
    end
  end

  describe ".search_catalog_query / .get_product_query" do
    it "configures a query that's known only after Shopify.configure runs — not baked into a frozen constant" do
      before_configure = described_class.search_catalog_query
      Portage::Ucp::Shopify.configure { |c| c.metadata_field(:color_hex, metafield: "custom.color_code") }
      after_configure = described_class.search_catalog_query

      expect(before_configure).not_to include("metafields(identifiers:")
      expect(after_configure).to include("metafields(identifiers:")
    end
  end
end
