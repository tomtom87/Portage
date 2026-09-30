require "spec_helper"
require "json"
require "stringio"

# `portage index search`, `index show --products` paging and
# `index add --crawl` (docs/plans/local-catalogue.md Phase 2). The index
# paths are redirected to a per-example tmpdir by spec_helper.
RSpec.describe Portage::Cli do
  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end

  let(:products) { Portage::Cli::Index::ProductStore.new }

  def seed
    products.upsert("title:brass-wall-light", origin: "https://yard.example", seen_at: 1, title: "Brass Wall Light",
                                              brand: "Yard", category: "594", url: "https://yard.example/products/b")
    products.upsert("title:glass-pendant", origin: "https://other.example", seen_at: 1, title: "Glass Pendant",
                                           brand: "Brass & Co", category: "594")
  end

  describe "index search" do
    before { seed }

    it "prints matching index entries as JSON, with the filters it applied" do
      output = capture_stdout do
        expect(described_class.run(%w[index search brass --store other.example --limit 5 --json])).to eq(0)
      end

      result = JSON.parse(output)
      expect(result).to include("query" => "brass", "engine" => "fts5",
                                "filters" => { "category" => nil, "store" => "other.example", "limit" => 5 })
      expect(result["products"].map { |p| p["title"] }).to eq(["Glass Pendant"])
    end

    it "joins a multi-word query and passes --category through" do
      output = capture_stdout { described_class.run(%w[index search brass wall --category 594 --json]) }

      expect(JSON.parse(output)["products"].map { |p| p["title"] }).to eq(["Brass Wall Light"])
    end

    it "prints one line per hit in text mode, and exits 1 with no hits" do
      output = capture_stdout { expect(described_class.run(%w[index search brass])).to eq(0) }
      expect(output).to include("Brass Wall Light — Yard (yard.example) https://yard.example/products/b")

      none = capture_stdout { expect(described_class.run(%w[index search zebra])).to eq(1) }
      expect(none).to include("No index products match")
    end

    it "prints usage with no query" do
      expect { expect(described_class.run(%w[index search])).to eq(1) }.to output.to_stderr
    end
  end

  describe "index search cards" do
    before do
      products.upsert("title:brass-wall-light", origin: "https://yard.example", seen_at: 1, title: "Brass Wall Light",
                                                brand: "Yard", category: "594", handle: "b", url: "https://yard.example/products/b",
                                                image_url: "https://cdn.example/b.jpg", variant_ids: ["gid://v/1"])
    end

    it "marks results live: false and gives each a product wire hash with no price" do
      result = JSON.parse(capture_stdout { described_class.run(%w[index search brass --json]) })

      expect(result["live"]).to be(false)
      expect(result["products"].first["product"]).to include(
        "title" => "Brass Wall Light", "url" => "https://yard.example/products/b",
        "media" => [{ "type" => "image", "url" => "https://cdn.example/b.jpg" }],
        "variants" => [{ "id" => "gid://v/1" }]
      )
      expect(JSON.generate(result)).not_to match(/"(price|amount|currency|available)/)
    end

    it "says in text mode that the hit is not live" do
      output = capture_stdout { described_class.run(%w[index search brass]) }

      expect(output).to include("not live")
    end
  end

  describe "index show --products" do
    before { seed }

    it "pages products, reporting the page and the total" do
      output = capture_stdout do
        expect(described_class.run(%w[index show --products --page 2 --per-page 1 --json])).to eq(0)
      end

      expect(JSON.parse(output)).to eq("stores" => [], "products" => [products.find("title:glass-pendant")],
                                       "page" => 2, "per_page" => 1, "products_total" => 2)
    end

    it "says in text mode which slice it printed" do
      output = capture_stdout { described_class.run(%w[index show --products --per-page 1]) }

      expect(output).to include("Brass Wall Light").and include("Showing 1-1 of 2")
      expect(output).not_to include("Glass Pendant")
    end
  end

  describe "index add --crawl" do
    it "passes crawl: true through to the builder" do
      builder = instance_double(Portage::Cli::Index::Builder)
      allow(builder).to receive(:add).with("https://shop.example", crawl: true)
                                     .and_return({ added: true, origin: "https://shop.example", message: "Added." })
      allow(Portage::Cli::Index::Builder).to receive(:new).and_return(builder)

      expect(capture_stdout { described_class.run(%w[index add https://shop.example --crawl]) }).to include("Added.")
    end
  end
end
