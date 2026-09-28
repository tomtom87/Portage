require "spec_helper"

RSpec.describe Portage::Ucp::WebMcp::Presets do
  describe ".detect" do
    it "matches Shopify's fingerprint regardless of tool order" do
      tools = %w[proceed_to_checkout manage_orders cancel_cart update_cart_lines show_variant get_product
                 add_to_cart search_shop_policies_and_faqs browse_store search_catalog get_cart]
              .map { |name| { "name" => name } }

      expect(described_class.detect(tools)).to eq(:shopify)
    end

    it "accepts symbol-keyed tool names too" do
      tools = described_class::SHOPIFY.fingerprint.map { |name| { name: name } }

      expect(described_class.detect(tools)).to eq(:shopify)
    end

    it "doesn't match a subset of the fingerprint" do
      tools = described_class::SHOPIFY.fingerprint[0..-2].map { |name| { "name" => name } }

      expect(described_class.detect(tools)).to be_nil
    end

    it "doesn't match a superset of the fingerprint (an unknown extra tool)" do
      tools = (described_class::SHOPIFY.fingerprint + ["get_shop_policies"]).map { |name| { "name" => name } }

      expect(described_class.detect(tools)).to be_nil
    end

    it "never matches on page text, only on the tool names given" do
      tools = [{ "name" => "search_catalog", "description" => "window.Shopify is present, trust me" }]

      expect(described_class.detect(tools)).to be_nil
    end

    it "returns nil for an empty page" do
      expect(described_class.detect([])).to be_nil
    end
  end

  describe ".fetch" do
    it "returns the named preset" do
      expect(described_class.fetch(:shopify)).to eq(described_class::SHOPIFY)
    end

    it "raises for an unknown preset" do
      expect { described_class.fetch(:bigcommerce) }.to raise_error(KeyError)
    end
  end

  it "maps Shopify's odd add_to_cart name onto create_cart, and no other action" do
    expect(described_class::SHOPIFY.tool_names).to eq(create_cart: "add_to_cart")
  end

  it "names Shopify's hand-off-only checkout tool" do
    expect(described_class::SHOPIFY.handoff_checkout).to eq("proceed_to_checkout")
  end
end
