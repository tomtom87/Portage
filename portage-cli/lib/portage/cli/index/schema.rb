require "sqlite3"

module Portage
  module Cli
    module Index
      # The SQL behind Index::Database, forward-only: MIGRATIONS[n] takes
      # user_version n to n + 1.
      module Schema
        # Kept minimal: `data` is the entry's JSON verbatim. `products`
        # carries an integer id (rather than the key alone being the
        # primary key) only so products_fts can share its rowid, which
        # stays stable across VACUUM.
        SCHEMA = <<~SQL.freeze
          CREATE TABLE stores (origin TEXT PRIMARY KEY, data TEXT NOT NULL);
          CREATE TABLE products (id INTEGER PRIMARY KEY, key TEXT NOT NULL UNIQUE, data TEXT NOT NULL);
          CREATE TABLE product_stores (key TEXT NOT NULL, origin TEXT NOT NULL, last_seen INTEGER,
                                       PRIMARY KEY (key, origin));
          CREATE TRIGGER products_stores_ins AFTER INSERT ON products BEGIN
            INSERT OR REPLACE INTO product_stores (key, origin, last_seen)
              SELECT new.key, json_extract(value, '$.origin'), json_extract(value, '$.last_seen')
              FROM json_each(new.data, '$.stores');
          END;
          CREATE TRIGGER products_stores_upd AFTER UPDATE OF data ON products BEGIN
            DELETE FROM product_stores WHERE key = old.key;
            INSERT OR REPLACE INTO product_stores (key, origin, last_seen)
              SELECT new.key, json_extract(value, '$.origin'), json_extract(value, '$.last_seen')
              FROM json_each(new.data, '$.stores');
          END;
        SQL

        # Needs FTS5 compiled in, which the gem's bundled SQLite has and a
        # system-libraries build might not — see fts5_available?.
        FTS_SCHEMA = <<~SQL.freeze
          CREATE VIRTUAL TABLE products_fts USING fts5(key UNINDEXED, title, brand, category, aliases);
          CREATE TRIGGER products_fts_ins AFTER INSERT ON products BEGIN
            INSERT INTO products_fts (rowid, key, title, brand, category, aliases)
              VALUES (new.id, new.key, json_extract(new.data, '$.title'), json_extract(new.data, '$.brand'),
                      json_extract(new.data, '$.category'),
                      (SELECT group_concat(value, ' ') FROM json_each(new.data, '$.aliases')));
          END;
          CREATE TRIGGER products_fts_upd AFTER UPDATE OF data ON products BEGIN
            DELETE FROM products_fts WHERE rowid = old.id;
            INSERT INTO products_fts (rowid, key, title, brand, category, aliases)
              VALUES (new.id, new.key, json_extract(new.data, '$.title'), json_extract(new.data, '$.brand'),
                      json_extract(new.data, '$.category'),
                      (SELECT group_concat(value, ' ') FROM json_each(new.data, '$.aliases')));
          END;
          CREATE TRIGGER products_fts_del AFTER DELETE ON products BEGIN
            DELETE FROM products_fts WHERE rowid = old.id;
          END;
        SQL

        # Each entry is a script run at that user_version. The FTS one is a
        # no-op on a build without FTS5 (its version still advances).
        MIGRATIONS = [
          ->(db) { db.execute_batch(SCHEMA) },
          ->(db) { db.execute_batch(FTS_SCHEMA) if Schema.fts5_available? }
        ].freeze

        # @return [Boolean] whether the linked SQLite was built with FTS5.
        def self.fts5_available?
          db = SQLite3::Database.new(":memory:")
          db.execute("PRAGMA compile_options").flatten.include?("ENABLE_FTS5")
        ensure
          db&.close
        end
      end
    end
  end
end
