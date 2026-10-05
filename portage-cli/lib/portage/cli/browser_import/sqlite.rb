require "sqlite3"
require "tmpdir"
require "fileutils"

module Portage
  module Cli
    module BrowserImport
      # Reads a browser's SQLite history database: the database (plus its
      # `-wal` file, when the browser left one — it holds the most recent
      # visits until the next checkpoint) is copied into a private tmpdir
      # first, since a running browser holds it locked, and the copy is
      # queried read-only through the sqlite3 gem. The `-shm` index is not
      # copied: SQLite rebuilds it from the `-wal` in the (writable) tmpdir.
      # The copy is deleted before this returns, success or not. The
      # original file is only ever read by the copy.
      #
      # Any SQLite error (a corrupt or non-SQLite file, a schema that
      # doesn't match the query) is Unavailable, never a fallback.
      class Sqlite
        class Unavailable < StandardError; end

        # Raised when macOS refuses to let this process read the file at
        # all (Safari's History.db without Full Disk Access). Never worked
        # around — see Importer's own handling.
        class PermissionDenied < StandardError; end

        # Copies `path` once and yields a query proc, so one copy serves
        # several queries (Firefox's history and bookmarks both live in
        # places.sqlite).
        # @yieldparam query [Proc] `query.call(sql)` => Array<Hash>
        def with_copy(path)
          Dir.mktmpdir("portage-browser-import") do |dir|
            copy = copy_database(path, dir)
            yield ->(sql) { run(copy, sql) }
          end
        end

        private

        def copy_database(path, dir)
          copy = File.join(dir, "copy.sqlite")
          FileUtils.cp(path, copy)
          FileUtils.cp("#{path}-wal", "#{copy}-wal") if File.exist?("#{path}-wal")
          copy
        rescue Errno::EPERM, Errno::EACCES => e
          raise PermissionDenied, e.message
        end

        def run(copy, sql)
          db = SQLite3::Database.new(copy, readonly: true, results_as_hash: true)
          db.execute(sql).map { |row| row.transform_values { |v| v.is_a?(String) ? scrub(v) : v } }
        rescue SQLite3::Exception => e
          raise Unavailable, "SQLite error: #{e.message}"
        ensure
          db&.close
        end

        def scrub(text) = text.dup.force_encoding("UTF-8").scrub
      end
    end
  end
end
