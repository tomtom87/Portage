require "spec_helper"
require "json"

# docs/plans/local-catalogue.md Phase 3: an index entry as the persisted
# subset of a UCP Product wire hash, never with a price.
RSpec.describe Portage::Cli::Index::EntryProduct do
  let(:entry) do
    { "key" => "title:brass-wall-light", "title" => "Brass Wall Light", "brand" => "Yard", "gtin" => nil,
      "category" => "594", "aliases" => [], "stores" => [{ "origin" => "https://yard.example", "last_seen" => 1 }],
      "sources" => ["storefront_products"], "handle" => "brass-wall-light",
      "url" => "https://yard.example/products/brass-wall-light",
      "image_url" => "https://cdn.example/brass.jpg",
      "options" => [{ "name" => "Finish", "values" => [{ "label" => "Brass" }, { "label" => "Nickel" }] }],
      "variant_ids" => ["gid://shopify/ProductVariant/1", "gid://shopify/ProductVariant/2"] }
  end

  it "maps the persisted fields onto UCP Product wire fields" do
    expect(described_class.wire(entry)).to eq(
      "title" => "Brass Wall Light", "handle" => "brass-wall-light",
      "url" => "https://yard.example/products/brass-wall-light",
      "media" => [{ "type" => "image", "url" => "https://cdn.example/brass.jpg" }],
      "options" => [{ "name" => "Finish", "values" => [{ "label" => "Brass" }, { "label" => "Nickel" }] }],
      "variants" => [{ "id" => "gid://shopify/ProductVariant/1" }, { "id" => "gid://shopify/ProductVariant/2" }],
      "categories" => [{ "value" => "594", "taxonomy" => "google_product_category" }]
    )
  end

  it "never carries a price, an availability or a price range" do
    json = JSON.generate(described_class.wire(entry))

    expect(json).not_to match(/price|amount|currency|availab/)
  end

  it "leaves out what the entry never had, rather than faking it" do
    bare = { "key" => "title:x", "title" => "Plain" }

    expect(described_class.wire(bare)).to eq("title" => "Plain")
  end
end
