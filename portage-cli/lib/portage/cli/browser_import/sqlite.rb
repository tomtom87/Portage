require "json"
require "open3"
require "tmpdir"
require "fileutils"

module Portage
  module Cli
    module BrowserImport
      # Reads a browser's SQLite history database without a native gem:
      # the database (plus its `-wal` file, when the browser left one — it
      # holds the most recent visits until the next checkpoint) is copied
      # into a private tmpdir first, since a running browser holds it
      # locked, and the copy is queried with the system `sqlite3` CLI in
      # `-readonly -json` mode. The copy is deleted before this returns,
      # success or not. The original file is only ever read by the copy.
      #
      # `sqlite3` ships with macOS and every mainstream Linux distro; when
      # it's missing, Unavailable says so rather than falling back to
      # anything else.
      class Sqlite
        class Unavailable < StandardError; end

        # Raised when macOS refuses to let this process read the file at
        # all (Safari's History.db without Full Disk Access). Never worked
        # around — see Importer's own handling.
        class PermissionDenied < StandardError; end

        # @param command [String] the sqlite3 executable — injectable so a
        #   spec can prove the missing-binary path without uninstalling it.
        def initialize(command: "sqlite3")
          @command = command
        end

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
          out, err, status = Open3.capture3(@command, "-readonly", "-json", copy, sql)
          raise Unavailable, "sqlite3 failed: #{err.strip}" unless status.success?

          text = out.dup.force_encoding("UTF-8").scrub
          text.strip.empty? ? [] : JSON.parse(text)
        rescue Errno::ENOENT
          raise Unavailable, "the sqlite3 command isn't installed (it ships with macOS and most Linux distros)"
        end
      end
    end
  end
end
