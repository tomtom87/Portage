require "spec_helper"

RSpec.describe Portage::Ucp::Shopify::Configuration do
  after do
    Portage::Ucp::Shopify.instance_variable_set(:@configuration, nil)
  end

  it "starts with no configured metadata fields for either scope" do
    config = described_class.new

    expect(config.fields_for(:product)).to eq([])
    expect(config.fields_for(:variant)).to eq([])
  end

  it "splits metafield: on the first dot into namespace and key" do
    config = described_class.new

    config.metadata_field(:color_hex, metafield: "custom.color_code")

    expect(config.fields_for(:product)).to eq(
      [{ key: "color_hex", namespace: "custom", metafield_key: "color_code" }]
    )
  end

  it "defaults scope: to :product" do
    config = described_class.new

    config.metadata_field(:fabric_content, metafield: "custom.fabric")

    expect(config.fields_for(:product).size).to eq(1)
    expect(config.fields_for(:variant)).to eq([])
  end

  it "files a variant-scoped field separately from product-scoped ones" do
    config = described_class.new

    config.metadata_field(:fabric_content, metafield: "custom.fabric", scope: :product)
    config.metadata_field(:color_hex, metafield: "custom.color_code", scope: :variant)

    expect(config.fields_for(:product).map { |f| f[:key] }).to eq(["fabric_content"])
    expect(config.fields_for(:variant).map { |f| f[:key] }).to eq(["color_hex"])
  end

  it "raises when metafield: has no dot to split a namespace from" do
    config = described_class.new

    expect { config.metadata_field(:color_hex, metafield: "color_code") }
      .to raise_error(described_class::InvalidMetadataField, /namespace\.key/)
  end

  it "raises on an unknown scope" do
    config = described_class.new

    expect { config.metadata_field(:color_hex, metafield: "custom.color_code", scope: :order) }
      .to raise_error(described_class::InvalidMetadataField, /:product or :variant/)
  end

  it "raises rather than exceed Shopify's 250-identifier metafields(identifiers:) cap" do
    config = described_class.new
    described_class::MAX_METAFIELD_IDENTIFIERS.times do |n|
      config.metadata_field(:"field_#{n}", metafield: "custom.field_#{n}")
    end

    expect { config.metadata_field(:one_too_many, metafield: "custom.overflow") }
      .to raise_error(described_class::InvalidMetadataField, /250-identifier/)
  end

  describe "Portage::Ucp::Shopify.configure / .configuration" do
    it "yields the same configuration instance every call, letting a consumer set it once" do
      Portage::Ucp::Shopify.configure { |c| c.metadata_field(:color_hex, metafield: "custom.color_code") }

      expect(Portage::Ucp::Shopify.configuration.fields_for(:product).map { |f| f[:key] }).to eq(["color_hex"])
    end
  end
end
