require "spec_helper"
require "tmpdir"
require_relative "fixtures"

RSpec.describe Portage::Cli::BrowserImport::Readers do
  include BrowserImportFixtures

  around do |example|
    Dir.mktmpdir { |dir| @root = dir and example.run }
  end

  let(:profiles) { Portage::Cli::BrowserImport::Profiles }
  let(:since) { Time.now.to_i - (90 * 86_400) }

  describe "Chromium" do
    it "reads history inside the window and bookmarks with their folder names" do
      chrome_profile(@root, visits: [{ url: "https://shop.example/products/trail-boots", title: "Trail Boots",
                                       visits: 4, days_ago: 2 },
                                     { url: "https://old.example/", title: "Old", days_ago: 200 }],
                            bookmarks: chrome_bookmarks("Outdoor" => [["https://gear.example/", "Gear Co"]]))
      profile = profiles.locate("chrome", root: @root).first
      reader = described_class.for("chromium")

      expect(reader.history(profile, since: since))
        .to eq([{ kind: "history", url: "https://shop.example/products/trail-boots", title: "Trail Boots",
                  folder: "", visits: 4 }])
      expect(reader.bookmarks(profile))
        .to eq([{ kind: "bookmark", url: "https://gear.example/", title: "Gear Co", folder: "Outdoor", visits: 1 }])
    end

    it "queries a copy, never the locked original, and deletes the copy afterwards" do
      chrome_profile(@root, visits: [{ url: "https://shop.example/", title: "Shop" }])
      profile = profiles.locate("chrome", root: @root).first
      opened = []
      allow(SQLite3::Database).to receive(:new).and_wrap_original do |original, path, *args, **kwargs|
        opened << [path, kwargs]
        original.call(path, *args, **kwargs)
      end

      described_class.for("chromium").history(profile, since: since)

      db_arg, options = opened.first
      expect(options).to include(readonly: true)
      expect(db_arg).not_to eq(profile.history)
      expect(File.exist?(db_arg)).to be(false)
    end

    it "sees visits still in the -wal file, without the browser's -shm" do
      dir = chrome_profile(@root)
      db = SQLite3::Database.new(File.join(dir, "History"))
      db.execute("PRAGMA journal_mode = WAL")
      db.execute("PRAGMA wal_autocheckpoint = 0")
      at = (Time.now.to_i + 11_644_473_600) * 1_000_000
      db.execute("INSERT INTO urls (url, title, visit_count, last_visit_time) VALUES (?, ?, ?, ?)",
                 ["https://wal.example/", "Wal", 2, at])
      expect(File.size(File.join(dir, "History-wal"))).to be > 0
      profile = profiles.locate("chrome", root: @root).first

      expect(described_class.for("chromium").history(profile, since: since).map { |r| r[:url] })
        .to eq(["https://wal.example/"])
    ensure
      db&.close
    end

    it "reports a file that isn't a SQLite database as Unavailable rather than falling back to anything else" do
      dir = chrome_profile(@root)
      File.write(File.join(dir, "History"), "not a database at all" * 100)
      profile = profiles.locate("chrome", root: @root).first

      expect { described_class.for("chromium").history(profile, since: since) }
        .to raise_error(Portage::Cli::BrowserImport::Sqlite::Unavailable, /SQLite error/)
    end
  end

  describe "Firefox" do
    it "reads history and bookmarks from one places.sqlite" do
      firefox_profile(@root, visits: [{ url: "https://shop.example/collections/tents", title: "Tents", visits: 3 }],
                             bookmarks: [[1, "My tent shop"]])
      profile = profiles.locate("firefox", root: @root).first
      reader = described_class.for("firefox")

      expect(reader.history(profile, since: since).map { |r| r.values_at(:url, :visits) })
        .to eq([["https://shop.example/collections/tents", 3]])
      expect(reader.bookmarks(profile))
        .to eq([{ kind: "bookmark", url: "https://shop.example/collections/tents", title: "My tent shop",
                  folder: "Gear", visits: 1 }])
    end
  end

  describe "Safari" do
    it "turns a permission error (no Full Disk Access) into PermissionDenied, never a workaround" do
      File.write(File.join(@root, "History.db"), "")
      File.write(File.join(@root, "Bookmarks.plist"), "")
      profile = profiles.locate("safari", root: @root).first
      allow(FileUtils).to receive(:cp).and_raise(Errno::EPERM, "Operation not permitted")

      expect { described_class.for("safari").history(profile, since: since) }
        .to raise_error(Portage::Cli::BrowserImport::Sqlite::PermissionDenied)
      expect { described_class.for("safari").bookmarks(profile) }
        .to raise_error(Portage::Cli::BrowserImport::Sqlite::PermissionDenied)
    end

    it "reads a binary Bookmarks.plist through plutil, with folder titles" do
      skip "plutil not available (macOS only)" unless plutil_available?

      xml = File.join(@root, "Bookmarks.xml")
      File.write(xml, <<~XML)
        <?xml version="1.0" encoding="UTF-8"?>
        <plist version="1.0"><dict><key>Children</key><array>
          <dict><key>Title</key><string>Shopping</string><key>Children</key><array>
            <dict><key>URLString</key><string>https://shop.example/</string>
              <key>URIDictionary</key><dict><key>title</key><string>Shop</string></dict>
              <key>ReadingList</key><dict><key>DateAdded</key><date>2026-01-01T00:00:00Z</date></dict>
            </dict>
          </array></dict>
        </array></dict></plist>
      XML
      system("plutil", "-convert", "binary1", "-o", File.join(@root, "Bookmarks.plist"), xml, exception: true)
      File.delete(xml)
      profile = profiles.locate("safari", root: @root).first

      expect(described_class.for("safari").bookmarks(profile))
        .to eq([{ kind: "bookmark", url: "https://shop.example/", title: "Shop", folder: "Shopping", visits: 1 }])
    end

    it "reads History.db visits inside the window" do
      recent = Time.now.to_i - 86_400 - 978_307_200
      sqlite!(File.join(@root, "History.db"),
              "CREATE TABLE history_items (id INTEGER PRIMARY KEY, url TEXT, visit_count INTEGER); " \
              "CREATE TABLE history_visits (id INTEGER PRIMARY KEY, history_item INTEGER, visit_time REAL, " \
              "title TEXT); INSERT INTO history_items VALUES (1, 'https://shop.example/', 5); " \
              "INSERT INTO history_visits VALUES (1, 1, #{recent}, 'Shop'), (2, 1, 1.0, 'Ancient');")
      profile = profiles.locate("safari", root: @root).first

      expect(described_class.for("safari").history(profile, since: since))
        .to eq([{ kind: "history", url: "https://shop.example/", title: "Shop", folder: "", visits: 5 }])
    end
  end
end
