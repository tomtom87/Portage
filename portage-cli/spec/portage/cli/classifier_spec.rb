require "spec_helper"
require "tempfile"

RSpec.describe Portage::Cli::Classifier do
  around do |example|
    Tempfile.create(["categories", ".yml"]) do |known|
      known.write(<<~YAML)
        '166':
          name: Apparel & Accessories
          keywords:
          - apparel
          - clothing
        '187':
          name: Apparel & Accessories > Shoes
          keywords:
          - shoe
          - boot
        '635':
          name: Home & Garden > Furniture
          keywords:
          - furniture
          - sofa
        '1':
          name: Animals & Pet Supplies
          keywords:
          - pet
        '998':
          name: Legal Services
          keywords:
          - law
        '997':
          name: Health & Beauty > Hair Care
          keywords:
          - hair
        '996':
          name: Cameras & Optics > Photography
          keywords:
          - photography
        '995':
          name: Electronics > Batteries
          keywords:
          - battery
      YAML
      known.flush
      @known_path = known.path
      example.run
    end
  end

  def categories_for(text, user_path: "/nonexistent/categories.yml")
    described_class.categories_for(text, known_path: @known_path, user_path: user_path)
  end

  it "ranks a query by keyword hits, most hits first" do
    expect(categories_for("hiking boots")).to eq(["187"])
  end

  it "matches a product title" do
    expect(categories_for("Men's Leather Boots")).to eq(["187"])
  end

  it "matches a URL slug under /products/, splitting - and _ into words" do
    expect(categories_for("https://shop.example/products/leather_hiking-boots"))
      .to eq(["187"])
  end

  it "matches /collections/, /c/ and /category/ slugs the same way" do
    expect(categories_for("https://shop.example/collections/sofa-beds")).to eq(["635"])
    expect(categories_for("https://shop.example/c/sofa-beds")).to eq(["635"])
    expect(categories_for("https://shop.example/category/sofa-beds")).to eq(["635"])
  end

  it "returns nothing when no keyword matches" do
    expect(categories_for("a completely unrelated query")).to eq([])
  end

  it "ranks categories with more keyword hits ahead of categories with fewer" do
    expect(categories_for("boot shoe apparel")).to eq(%w[187 166])
  end

  describe "whole-word matching (no substring false positives)" do
    it "does not match 'carpet' to the pet-supplies keyword 'pet'" do
      expect(categories_for("carpet")).to eq([])
    end

    it "does not match 'lawn mower' to the legal keyword 'law'" do
      expect(categories_for("lawn mower")).to eq([])
    end

    it "does not match 'chair' to the hair-care keyword 'hair'" do
      expect(categories_for("chair")).to eq([])
    end

    it "does not match 'hot sauce' to the photography keyword 'photography'" do
      expect(categories_for("hot sauce")).to eq([])
    end

    it "still matches a plural against its singular keyword" do
      expect(categories_for("boots")).to eq(["187"])
      expect(categories_for("boot")).to eq(["187"])
    end

    it "still matches 'batteries' against the singular keyword 'battery'" do
      expect(categories_for("batteries")).to eq(["995"])
      expect(categories_for("battery")).to eq(["995"])
    end
  end

  describe "~/.portage/categories.yml" do
    it "overrides a shipped id's keywords" do
      Tempfile.create(["user-categories", ".yml"]) do |user|
        user.write(<<~YAML)
          '187':
            name: Apparel & Accessories > Shoes
            keywords:
            - sandal
        YAML
        user.flush

        expect(categories_for("sandal", user_path: user.path)).to eq(["187"])
        expect(categories_for("boot", user_path: user.path)).to eq([])
      end
    end

    it "extends the taxonomy with a new id" do
      Tempfile.create(["user-categories", ".yml"]) do |user|
        user.write(<<~YAML)
          '999999':
            name: Custom > Handmade Jewelry
            keywords:
            - jewelry
        YAML
        user.flush

        expect(categories_for("jewelry", user_path: user.path)).to eq(["999999"])
      end
    end

    it "is ignored when missing" do
      expect(categories_for("boot", user_path: "/nonexistent/categories.yml")).to eq(["187"])
    end
  end
end
