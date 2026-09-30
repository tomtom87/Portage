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

  describe "weighting" do
    def classify_in(yaml, text, user_path: "/nonexistent/categories.yml")
      Tempfile.create(["weights", ".yml"]) do |file|
        file.write(yaml)
        file.flush
        return described_class.categories_for(text, known_path: file.path, user_path: user_path)
      end
    end

    let(:weighted) do
      <<~YAML
        '10':
          name: Home & Garden > Decor
          keywords:
          - decor
          parent_keywords:
          - lamp
        '20':
          name: Home & Garden > Lighting
          keywords:
          - lamp
          - pendant
          parent_keywords:
          - home
        '30':
          name: Furniture
          keywords:
          - home
      YAML
    end

    it "scores a keyword 2 and a parent_keyword 1" do
      expect(classify_in(weighted, "lamp")).to eq(%w[20 10])
    end

    it "adds the two kinds of hit up, and drops a node scoring under half the best" do
      expect(classify_in(weighted, "home lamp")).to eq(%w[20 30])
    end

    it "lets one keyword outrank a parent_keyword even when the parent_keyword's node is first in the file" do
      expect(classify_in(weighted, "lamp").first).to eq("20")
    end

    it "lets two parent_keywords tie one keyword, and ties keep the file's order" do
      yaml = <<~YAML
        '1':
          name: A
          keywords:
          - alpha
        '2':
          name: B
          keywords:
          - zulu
          parent_keywords:
          - beta
          - gamma
      YAML
      expect(classify_in(yaml, "alpha beta gamma")).to eq(%w[1 2])
      expect(classify_in(yaml, "alpha beta")).to eq(%w[1 2])
      expect(classify_in(yaml, "beta")).to eq(%w[2])
    end

    it "counts a word once, even if it is both a keyword and a parent_keyword" do
      yaml = "'1':\n  name: A\n  keywords:\n  - alpha\n  parent_keywords:\n  - alpha\n"
      yaml += "'2':\n  name: B\n  keywords:\n  - alpha\n  - beta\n"
      expect(classify_in(yaml, "alpha")).to eq(%w[1 2])
    end

    it "still lets a user override replace a node's keywords and parent_keywords" do
      Tempfile.create(["user", ".yml"]) do |user|
        user.write("'20':\n  name: Home & Garden > Lighting\n  keywords:\n  - sconce\n")
        user.flush
        expect(classify_in(weighted, "lamp", user_path: user.path)).to eq(%w[10])
        expect(classify_in(weighted, "sconce", user_path: user.path)).to eq(%w[20])
        expect(classify_in(weighted, "home", user_path: user.path)).to eq(%w[30])
      end
    end
  end

  describe "word matching through the keyword index" do
    it "accepts exactly the words word_match? accepts" do
      keywords = %w[boot battery watch glass bus box party city]
      yaml = keywords.each_with_index.map { |word, i| "'#{i + 1}':\n  name: N#{i}\n  keywords:\n  - #{word}\n" }.join
      variants = keywords.flat_map do |k|
        [k, "#{k}s", "#{k}es", k.delete_suffix("s"), k.delete_suffix("es"), k.sub(/y\z/, "ies"), k.sub(/ies\z/, "y")]
      end
      words = variants.uniq.select { |word| word.length >= 3 } + %w[booty batteryes glasses passes]
      Tempfile.create(["index", ".yml"]) do |file|
        file.write(yaml)
        file.flush
        words.each do |word|
          found = described_class.categories_for(word, known_path: file.path, user_path: "/nonexistent",
                                                       stoplist_path: "/nonexistent")
          expected = keywords.each_index.select { |i| described_class.word_match?(word, keywords[i]) }
          expect(found.map(&:to_i).map { |n| n - 1 }.sort).to eq(expected), "#{word}: #{found}"
        end
      end
    end
  end

  describe "the length of the answer" do
    def classify_in(yaml, text)
      Tempfile.create(["answer", ".yml"]) do |file|
        file.write(yaml)
        file.flush
        return described_class.categories_for(text, known_path: file.path, user_path: "/nonexistent/categories.yml")
      end
    end

    def nodes(count, keywords)
      (1..count).map do |i|
        words = keywords.call(i).map { |word| "  - #{word}\n" }.join
        "'#{i}':\n  name: Node #{i}\n  keywords:\n#{words}"
      end.join
    end

    it "returns at most the three best ids, so a generic word cannot claim a dozen categories" do
      expect(classify_in(nodes(8, ->(_i) { %w[alpha] }), "alpha")).to eq(%w[1 2 3])
    end

    it "drops an id scoring under half the best one: a common word does not add a category" do
      yaml = nodes(6, ->(i) { i == 1 ? %w[alpha rare] : %w[alpha] })
      expect(classify_in(yaml, "alpha rare")).to eq(%w[1])
    end

    it "keeps an id scoring exactly half the best one" do
      yaml = "'1':\n  name: A\n  keywords:\n  - aaa\n  - bbb\n'2':\n  name: B\n  keywords:\n  - ccc\n"
      expect(classify_in(yaml, "aaa bbb ccc")).to eq(%w[1 2])
    end
  end

  describe "rare words" do
    it "outweigh common ones: a word in one node counts for more than a word in many" do
      yaml = <<~YAML
        '1':
          name: Tools
          keywords:
          - common
        '2':
          name: Kitchen
          keywords:
          - common
          - kettle
        '3':
          name: Lighting
          keywords:
          - common
        '4':
          name: Garden
          keywords:
          - common
      YAML
      Tempfile.create(["rare", ".yml"]) do |file|
        file.write(yaml)
        file.flush
        expect(described_class.categories_for("common kettle", known_path: file.path,
                                                               user_path: "/nonexistent")).to eq(%w[2])
      end
    end
  end

  describe "repeated words" do
    def classify_in(yaml, text)
      Tempfile.create(["repeats", ".yml"]) do |file|
        file.write(yaml)
        file.flush
        return described_class.categories_for(text, known_path: file.path, user_path: "/nonexistent/categories.yml")
      end
    end

    let(:two_nodes) do
      <<~YAML
        '1':
          name: Tools
          keywords:
          - strap
        '2':
          name: Lighting
          keywords:
          - pendant
      YAML
    end

    it "weighs a word the input repeats above a word it says once, as a tag list does" do
      expect(classify_in(two_nodes, "strap pendant")).to eq(%w[1 2])
      expect(classify_in(two_nodes, "strap pendant pendant")).to eq(%w[2 1])
    end

    it "counts a plural variant as a repeat of the same word" do
      expect(classify_in(two_nodes, "strap pendant pendants")).to eq(%w[2 1])
    end

    it "counts a word once for a node that lists both of its plural forms" do
      yaml = <<~YAML
        '1':
          name: Tools
          keywords:
          - light
          - lights
        '2':
          name: Lighting
          keywords:
          - pendant
      YAML
      expect(classify_in(yaml, "light lights pendant pendant")).to eq(%w[2 1])
    end

    it "grows slowly: five different words still outrank one word said twenty times" do
      yaml = <<~YAML
        '1':
          name: Tools
          keywords:
          - spanner
          - saw
          - drill
          - axe
          - vice
        '2':
          name: Lighting
          keywords:
          - pendant
      YAML
      expect(classify_in(yaml, "spanner saw drill axe vice #{'pendant ' * 20}")).to eq(%w[1 2])
    end
  end

  describe "ties" do
    def classify_in(yaml, text)
      Tempfile.create(["ties", ".yml"]) do |file|
        file.write(yaml)
        file.flush
        return described_class.categories_for(text, known_path: file.path, user_path: "/nonexistent/categories.yml")
      end
    end

    it "go to the node whose own name the input covers more of" do
      yaml = <<~YAML
        '1':
          name: Furniture > Sofa Accessories
          keywords:
          - sofa
        '2':
          name: Furniture > Sofas
          keywords:
          - sofas
      YAML
      expect(classify_in(yaml, "sofa")).to eq(%w[2 1])
    end

    it "then to the node whose name has no stoplisted word, the main node rather than its accessories" do
      yaml = <<~YAML
        '1':
          name: Home > Appliance Accessories
          keywords:
          - vacuum
        '2':
          name: Home > Appliances
          keywords:
          - vacuum
          - iron
      YAML
      Tempfile.create(["stop", ".yml"]) do |stop|
        stop.write("accessories: generic\n")
        stop.flush
        Tempfile.create(["ties", ".yml"]) do |file|
          file.write(yaml)
          file.flush
          found = described_class.categories_for("vacuum", known_path: file.path, user_path: "/nonexistent",
                                                           stoplist_path: stop.path)
          expect(found).to eq(%w[2 1])
        end
      end
    end

    it "then to the node with fewer keywords, the more specific one" do
      yaml = <<~YAML
        '1':
          name: Pets
          keywords:
          - treadmill
          - leash
          - collar
        '2':
          name: Fitness
          keywords:
          - treadmill
      YAML
      expect(classify_in(yaml, "treadmill")).to eq(%w[2 1])
    end

    it "then to the shipped file's own order" do
      yaml = "'1':\n  name: A\n  keywords:\n  - alpha\n'2':\n  name: B\n  keywords:\n  - alpha\n"
      expect(classify_in(yaml, "alpha")).to eq(%w[1 2])
    end

    it "cope with a user node that has no name" do
      expect(classify_in("'1':\n  keywords:\n  - alpha\n", "alpha")).to eq(%w[1])
    end
  end

  describe "the stoplist" do
    def stoplist_file(body)
      Tempfile.create(["stoplist", ".yml"]) do |file|
        file.write(body)
        file.flush
        yield file.path
      end
    end

    def classify(text, stoplist_path:)
      described_class.categories_for(text, known_path: @known_path, user_path: "/nonexistent",
                                           stoplist_path: stoplist_path)
    end

    it "ignores input words on it, so a stoplisted keyword cannot match" do
      stoplist_file("shoe: merchandising word\n") do |path|
        expect(classify("shoe", stoplist_path: path)).to eq([])
        expect(classify("shoe boot", stoplist_path: path)).to eq(["187"])
      end
    end

    it "matches a stoplisted word exactly, not its plural" do
      stoplist_file("shoe: merchandising word\n") do |path|
        expect(classify("shoes", stoplist_path: path)).to eq(["187"])
      end
    end

    it "is applied to url slug words as well as plain words" do
      stoplist_file("sofa: merchandising word\n") do |path|
        expect(classify("https://shop.example/products/sofa-beds", stoplist_path: path)).to eq([])
      end
    end

    it "is ignored when missing" do
      expect(classify("boot", stoplist_path: "/nonexistent/stoplist.yml")).to eq(["187"])
    end

    it "uses the shipped known-stores/category-stoplist.yml by default" do
      Tempfile.create(["merch", ".yml"]) do |known|
        known.write("'1':\n  name: Toll\n  keywords:\n  - collection\n  - sale\n  - gift\n")
        known.flush
        expect(described_class.categories_for("New Collection Sale", known_path: known.path,
                                                                     user_path: "/nonexistent")).to eq([])
      end
    end

    it "leaves Classifier.tokenize alone, because the index search shares it" do
      expect(described_class.tokenize("New Collection")).to eq(%w[new collection])
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
