require "spec_helper"
require "tmpdir"
require "rbconfig"

RSpec.describe Portage::Cli::Index::Database do
  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  let(:path) { File.join(@dir, "index", "index.sqlite3") }
  let(:db) { described_class.new(path: path) }
  let(:stores) { Portage::Cli::Index::Store.new(path: File.join(@dir, "index", "stores.json")) }
  let(:products) { Portage::Cli::Index::ProductStore.new(path: File.join(@dir, "index", "products.json")) }

  def write_json(name, data)
    FileUtils.mkdir_p(File.join(@dir, "index"))
    File.write(File.join(@dir, "index", name), JSON.generate(data))
  end

  it "derives the database path from a legacy json path" do
    expect(described_class.path_for("/x/index/stores.json")).to eq("/x/index/index.sqlite3")
  end

  describe "file posture" do
    it "creates nothing until something is written" do
      expect(db.entries("stores")).to eq({})
      expect(File.exist?(path)).to be false
      expect(db.exists?).to be false
    end

    it "creates the file 0600 and in WAL mode" do
      stores.upsert("https://a.example", last_verified: 1)

      expect(File.stat(path).mode & 0o777).to eq(0o600)
      expect(db.pragma("journal_mode")).to eq("wal")
    end

    it "keeps the -wal and -shm side files private too" do
      stores.upsert("https://a.example", last_verified: 1)
      held = described_class.new(path: path)
      held.entries("stores")

      side = Dir["#{path}-*"]
      expect(side).not_to be_empty
      expect(side.map { |f| File.stat(f).mode & 0o777 }.uniq).to eq([0o600])
    end

    it "raises when the database can't be written" do
      FileUtils.mkdir_p(File.dirname(path))
      FileUtils.chmod(0o500, File.dirname(path))
      skip "root ignores directory modes" if Process.uid.zero?

      expect { stores.upsert("https://a.example", last_verified: 1) }.to raise_error(Errno::EACCES)
    ensure
      FileUtils.chmod(0o700, File.dirname(path))
    end
  end

  describe "schema versioning" do
    it "stamps user_version after migrating" do
      stores.upsert("https://a.example", last_verified: 1)

      expect(described_class.new(path: path).pragma("user_version")).to eq(Portage::Cli::Index::Schema::MIGRATIONS.length)
    end

    it "refuses a database newer than this build understands" do
      stores.upsert("https://a.example", last_verified: 1)
      SQLite3::Database.new(path) { |raw| raw.execute("PRAGMA user_version = 999") }

      expect { described_class.new(path: path).entries("stores") }.to raise_error(described_class::Error, /newer/)
    end
  end

  describe "#transaction" do
    it "rolls everything back when the block raises" do
      stores.upsert("https://a.example", last_verified: 1)

      expect do
        db.transaction do
          db.put("stores", "https://b.example", { "origin" => "https://b.example" })
          raise "boom"
        end
      end.to raise_error("boom")

      expect(stores.all.map { |e| e["origin"] }).to eq(["https://a.example"])
    end

    it "nests without opening a second transaction" do
      db.transaction { db.transaction { db.put("stores", "https://a.example", { "origin" => "https://a.example" }) } }

      expect(db.count("stores")).to eq(1)
    end
  end

  describe "#info" do
    it "reports path, counts and FTS5 availability" do
      products.upsert("title:x", origin: "https://a.example", seen_at: 1, title: "X")

      expect(db.info).to eq(path: path, exists: true, stores: 0, products: 1, fts5: Portage::Cli::Index::Schema.fts5_available?)
    end

    it "reports zero counts for a database that doesn't exist yet" do
      expect(db.info).to include(exists: false, stores: 0, products: 0)
    end
  end

  describe "FTS5", if: Portage::Cli::Index::Schema.fts5_available? do
    it "indexes title, brand, category and aliases, following updates" do
      products.upsert("gtin:1", origin: "https://a.example", seen_at: 1, title: "Trail Boots", brand: "Lems",
                                category: "166")
      products.upsert("gtin:1", origin: "https://b.example", seen_at: 2, title: "Trailblazer")

      match = ->(q) { db.execute("SELECT key FROM products_fts WHERE products_fts MATCH ?", [q]).flatten }
      expect(match.call("trailblazer")).to eq(["gtin:1"])
      expect(match.call("boots")).to eq(["gtin:1"]) # alias
      expect(match.call("lems")).to eq(["gtin:1"])
    end
  end

  describe "product_stores" do
    it "mirrors the stores array of each product" do
      products.upsert("title:x", origin: "https://a.example", seen_at: 1, title: "X")
      products.upsert("title:x", origin: "https://b.example", seen_at: 5, title: "X")
      products.upsert("title:x", origin: "https://a.example", seen_at: 9, title: "X")

      rows = db.execute("SELECT key, origin, last_seen FROM product_stores ORDER BY origin")
      expect(rows).to eq([["title:x", "https://a.example", 9], ["title:x", "https://b.example", 5]])
    end
  end

  describe "surviving a fresh process" do
    it "reads back what an earlier process wrote" do
      stores.upsert("https://a.example", platform: "shopify", last_verified: 7)
      products.upsert("title:x", origin: "https://a.example", seen_at: 1, title: "Cafeé")

      lib = File.expand_path("../../../../lib", __dir__)
      script = 'require "portage/cli"; d = ARGV[0]; ' \
               "puts Portage::Cli::Index::Store.new(path: d + '/stores.json').find('https://a.example')['platform']; " \
               "puts Portage::Cli::Index::ProductStore.new(path: d + '/products.json').find('title:x')['title']"
      out = IO.popen([RbConfig.ruby, "-I", lib, "-e", script, File.join(@dir, "index")], err: File::NULL, &:read)

      expect(out.force_encoding("UTF-8").lines.map(&:chomp)).to eq(%W[shopify Cafe\u00E9])
    end
  end

  describe "JSON migration" do
    let(:store_entry) { { "origin" => "https://a.example", "platform" => "shopify", "last_verified" => 5 } }
    let(:product_entry) do
      { "key" => "title:x", "title" => "X", "aliases" => [], "stores" => [{ "origin" => "https://a.example",
                                                                            "last_seen" => 3 }] }
    end

    before do
      write_json("stores.json", { "https://a.example" => store_entry })
      write_json("products.json", { "title:x" => product_entry })
    end

    it "reports the index as existing before the first open" do
      expect(stores.exists?).to be true
    end

    it "imports both files verbatim on first open" do
      expect(stores.find("https://a.example")).to eq(store_entry)
      expect(products.find("title:x")).to eq(product_entry)
      expect(db.execute("SELECT origin FROM product_stores")).to eq([["https://a.example"]])
    end

    it "renames the originals to *.json.migrated and never deletes them" do
      stores.all
      products.all

      dir = File.join(@dir, "index")
      expect(File.exist?(File.join(dir, "stores.json"))).to be false
      expect(File.exist?(File.join(dir, "products.json"))).to be false
      expect(JSON.parse(File.read(File.join(dir, "stores.json.migrated")))).to eq("https://a.example" => store_entry)
      expect(File.exist?(File.join(dir, "products.json.migrated"))).to be true
    end

    it "imports exactly once" do
      stores.all
      stores.remove("a.example")
      write_json("stores.json", { "https://again.example" => { "origin" => "https://again.example" } })

      expect(described_class.new(path: path).entries("stores")).to eq({})
      expect(File.exist?(File.join(@dir, "index", "stores.json"))).to be true
    end

    it "doesn't import into a database that already has rows" do
      FileUtils.rm(File.join(@dir, "index", "stores.json"))
      stores.upsert("https://mine.example", last_verified: 1)
      write_json("stores.json", { "https://a.example" => store_entry })

      expect(described_class.new(path: path).entries("stores").keys).to eq(["https://mine.example"])
      expect(File.exist?(File.join(@dir, "index", "stores.json"))).to be true
    end

    it "leaves an unparseable file alone and starts empty" do
      File.write(File.join(@dir, "index", "stores.json"), "not json")

      expect(stores.all).to eq([])
      expect(File.read(File.join(@dir, "index", "stores.json"))).to eq("not json")
    end

    it "retries the import on the next open if it failed, leaving the database unstamped" do
      allow(Portage::Cli::Index::LegacyImport).to receive(:new).and_raise(RuntimeError, "boom")
      expect { stores.all }.to raise_error("boom")

      allow(Portage::Cli::Index::LegacyImport).to receive(:new).and_call_original
      expect(Portage::Cli::Index::Store.new(path: File.join(@dir, "index", "stores.json")).all).to eq([store_entry])
    end

    it "skips entries that aren't objects" do
      write_json("stores.json", { "https://a.example" => store_entry, "https://b.example" => "junk" })

      expect(stores.all).to eq([store_entry])
    end
  end
end
