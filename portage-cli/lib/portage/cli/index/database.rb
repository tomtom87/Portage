require "json"
require "fileutils"
require "sqlite3"
require_relative "schema"
require_relative "legacy_import"

module Portage
  module Cli
    module Index
      # `~/.portage/index/index.sqlite3` — the one file behind Index::Store
      # and Index::ProductStore (docs/plans/local-catalogue.md Phase 1).
      # Plain SQL over the `sqlite3` gem, no ORM: every entry is stored as
      # the same JSON object the old stores.json/products.json held, so the
      # entry shapes documented on Store/ProductStore did not change.
      #
      # Posture: the file is created 0600 (and so are SQLite's -wal/-shm
      # side files, which copy the main file's mode); it runs in WAL mode
      # with a busy timeout; a failed write raises rather than being
      # swallowed. Nothing is created until something is written — a read
      # of an index that doesn't exist yet just comes back empty.
      #
      # Forward-only schema: MIGRATIONS[n] takes user_version n to n + 1,
      # and a database stamped newer than this build knows is refused
      # rather than guessed at.
      #
      # The open that creates the database also imports a legacy stores.json/
      # products.json that sits beside it, in one transaction, then renames
      # it to *.json.migrated. Only that one open does — later opens never
      # look, even if the tables have since been emptied — and nothing is
      # ever deleted.
      class Database
        class Error < StandardError; end

        FILENAME = "index.sqlite3".freeze
        BUSY_TIMEOUT_MS = 5_000

        # table => its key column. The legacy json file for a table is
        # "<table>.json".
        TABLES = { "stores" => "origin", "products" => "key" }.freeze

        # The database that lives beside a legacy stores.json/products.json.
        def self.path_for(json_path) = File.join(File.dirname(json_path), FILENAME)

        attr_reader :path

        def initialize(path:)
          @path = path
        end

        # True once there is something to read: the database itself, or a
        # legacy json file that the next open will import.
        def exists? = File.exist?(@path) || LegacyImport.files(File.dirname(@path)).any?

        # @return [Hash] key => parsed entry, in insertion order.
        def entries(table)
          return {} unless exists?

          execute("SELECT #{TABLES.fetch(table)}, data FROM #{table} ORDER BY rowid").to_h { |k, d| [k, JSON.parse(d)] }
        end

        def get(table, key)
          return nil unless exists?

          row = execute("SELECT data FROM #{table} WHERE #{TABLES.fetch(table)} = ?", [key]).first
          row && JSON.parse(row.first)
        end

        def put(table, key, entry)
          column = TABLES.fetch(table)
          execute("INSERT INTO #{table} (#{column}, data) VALUES (?, ?) " \
                  "ON CONFLICT(#{column}) DO UPDATE SET data = excluded.data", [key, JSON.generate(entry)])
        end

        def delete(table, key)
          execute("DELETE FROM #{table} WHERE #{TABLES.fetch(table)} = ?", [key])
        end

        def count(table)
          return 0 unless exists?

          execute("SELECT COUNT(*) FROM #{table}").first.first
        end

        # Reentrant: a nested call joins the outer transaction. IMMEDIATE
        # takes the write lock up front, so a read-modify-write inside it
        # can't interleave with another process's.
        def transaction(&)
          return yield if connection.transaction_active?

          connection.transaction(:immediate, &)
        end

        # @return [Array<Array>] raw rows — for the specs and Phase 2's
        #   search; everything else goes through the entry methods above.
        def execute(sql, binds = [])
          connection.execute(sql, binds)
        end

        def pragma(name) = execute("PRAGMA #{name}").flatten.first

        # What `portage doctor` reports.
        def info
          stores = count("stores")
          products = count("products")
          { path: @path, exists: File.exist?(@path), stores: stores, products: products,
            fts5: Schema.fts5_available? }
        end

        private

        def connection
          @connection ||= open_connection
        end

        def open_connection
          FileUtils.mkdir_p(File.dirname(@path))
          File.open(@path, File::CREAT | File::WRONLY, 0o600) { nil }
          FileUtils.chmod(0o600, @path)
          db = SQLite3::Database.new(@path)
          db.busy_timeout = BUSY_TIMEOUT_MS
          db.execute("PRAGMA journal_mode = WAL")
          db.execute("PRAGMA synchronous = NORMAL")
          @connection = db
          # One transaction, so a failed import leaves the database unstamped
          # and the next open tries again rather than skipping the import.
          transaction { LegacyImport.new(self, File.dirname(@path)).call if migrate.zero? }
          db
        rescue StandardError
          @connection&.close
          @connection = nil
          raise
        end

        def migrate
          version = @connection.get_first_value("PRAGMA user_version")
          if version > Schema::MIGRATIONS.length
            raise Error,
                  "#{@path} is schema v#{version}, newer than this portage understands"
          end

          Schema::MIGRATIONS.drop(version).each_with_index do |step, i|
            step.call(@connection)
            @connection.execute("PRAGMA user_version = #{version + i + 1}")
          end
          version
        end
      end
    end
  end
end
