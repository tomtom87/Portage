require "spec_helper"
require "json"

RSpec.describe Portage::Cli::Index::Sources::StorefrontProducts::Mapper do
  # Trimmed from thelightyard.co.uk/products.json (2026-09-30): the first
  # product is a single-variant "Default Title" product, the second has a
  # real option with two variants, each with a featured image.
  let(:raw_products) do
    path = File.expand_path("../../../../../fixtures/index/storefront_products.json", __dir__)
    JSON.parse(File.read(path, encoding: "UTF-8"))["products"]
  end
  let(:single) { raw_products[0] }
  let(:multi) { raw_products[1] }
  let(:origin) { "https://thelightyard.co.uk" }
  let(:classify) { ->(_text) { %w[638 6915 4163 500] } }

  describe ".product" do
    it "maps a products.json product into the UCP Product wire shape" do
      product = described_class.product(multi, origin: origin, classify: classify)

      expect(product).to be_a(Portage::Ucp::Product)
      wire = product.to_wire_h
      expect(wire).to include(
        "id" => "gid://shopify/Product/15423451562359",
        "title" => "SIGNATURE MOROCCAN GOLD LEAF PENDANT LIGHT",
        "handle" => "signature-moroccan-gold-leaf-pendant-light",
        "url" => "https://thelightyard.co.uk/products/signature-moroccan-gold-leaf-pendant-light",
        "description" => { "html" => "<p>Hand-cut glass and solid brass, made in Derbyshire.</p>" },
        "options" => [{ "name" => "Select Your Ceiling Kit (Bulb Included)",
                        "values" => [{ "label" => "ANTIQUE BRONZE" }, { "label" => "BRUSHED BRASS" }] }],
        "categories" => [{ "value" => "638", "taxonomy" => "google_product_category" },
                         { "value" => "6915", "taxonomy" => "google_product_category" },
                         { "value" => "4163", "taxonomy" => "google_product_category" },
                         { "value" => "Pendant Light", "taxonomy" => "merchant" }],
        "tags" => multi["tags"]
      )
      expect(wire["media"].first).to eq(
        "type" => "image", "url" => multi["images"][0]["src"], "width" => 700, "height" => 1000
      )
      expect(wire["variants"].map { |v| v.slice("id", "title", "sku", "options") }).to eq(
        [{ "id" => "gid://shopify/ProductVariant/56914542821751", "title" => "ANTIQUE BRONZE",
           "sku" => "A/PEN/SIG/G-MOR/S/ANT",
           "options" => [{ "name" => "Select Your Ceiling Kit (Bulb Included)", "label" => "ANTIQUE BRONZE" }] },
         { "id" => "gid://shopify/ProductVariant/56914542854519", "title" => "BRUSHED BRASS",
           "sku" => "A/PEN/SIG/G-MOR/S/BB",
           "options" => [{ "name" => "Select Your Ceiling Kit (Bulb Included)", "label" => "BRUSHED BRASS" }] }]
      )
      expect(wire["variants"].first["media"].first["alt_text"]).to start_with("Elegant, rectangular Moroccan")
    end

    it "carries the store's price and availability on the Product (products.json has no currency)" do
      wire = described_class.product(multi, origin: origin, classify: classify).to_wire_h

      expect(wire["price_range"]).to eq("min" => { "amount" => 43_000, "currency" => nil },
                                        "max" => { "amount" => 43_000, "currency" => nil })
      expect(wire["variants"].first).to include("price" => { "amount" => 43_000, "currency" => nil },
                                                "availability" => { "available" => true })
    end

    it "drops Shopify's placeholder 'Title: Default Title' option" do
      wire = described_class.product(single, origin: origin, classify: classify).to_wire_h

      expect(wire).not_to have_key("options")
      expect(wire["variants"].first).not_to have_key("options")
    end

    it "classifies on product_type and tags, keeping the top three ids" do
      seen = []
      classify = lambda { |text|
        seen << text
        %w[1 2 3 4]
      }

      product = described_class.product(multi, origin: origin, classify: classify)

      expect(seen).to eq([["Pendant Light", *multi["tags"]].join(" ")])
      expect(product.categories.map(&:value)).to eq(["1", "2", "3", "Pendant Light"])
    end
  end

  describe ".sighting" do
    it "is the index entry subset of the Product, with no price or availability anywhere" do
      sighting = described_class.sighting(multi, origin: origin, classify: classify)

      expect(sighting).to eq(
        origin: origin,
        url: "https://thelightyard.co.uk/products/signature-moroccan-gold-leaf-pendant-light",
        title: "SIGNATURE MOROCCAN GOLD LEAF PENDANT LIGHT",
        brand: "The Alchemist Collection By Gwyn Carless At The Light Yard",
        gtin: nil,
        categories: %w[638 6915 4163],
        product: {
          handle: "signature-moroccan-gold-leaf-pendant-light",
          url: "https://thelightyard.co.uk/products/signature-moroccan-gold-leaf-pendant-light",
          image_url: multi["images"][0]["src"],
          options: [{ "name" => "Select Your Ceiling Kit (Bulb Included)",
                      "values" => [{ "label" => "ANTIQUE BRONZE" }, { "label" => "BRUSHED BRASS" }] }],
          variant_ids: %w[gid://shopify/ProductVariant/56914542821751 gid://shopify/ProductVariant/56914542854519]
        }
      )
      expect(JSON.generate(sighting)).not_to match(/price|availab|430\.00|43000/)
    end

    it "leaves brand nil for a blank vendor and image_url nil with no images" do
      sighting = described_class.sighting(single.merge("vendor" => " ", "images" => []), origin: origin,
                                                                                         classify: classify)

      expect(sighting[:brand]).to be_nil
      expect(sighting[:product][:image_url]).to be_nil
      expect(sighting[:product][:options]).to eq([])
    end
  end
end
