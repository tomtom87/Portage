require "json"
require "open3"
require "tmpdir"
require "fileutils"

require_relative "sqlite"
require_relative "plist_xml"

module Portage
  module Cli
    module BrowserImport
      # One reader per browser family. Each turns a Profiles::Profile into
      # plain rows — `{ kind: "history"|"bookmark", url:, title:, folder:,
      # visits: }` — and reads nothing but that profile's own allowed files
      # (Profiles::ALLOWED_FILES). A row is just what the browser recorded;
      # reducing it to a domain, filtering and probing is Importer's job.
      module Readers
        # Seconds between the Unix epoch and each browser's own clock:
        # Chromium counts microseconds from 1601-01-01, Safari (Core Data)
        # seconds from 2001-01-01, Firefox microseconds from the Unix epoch.
        WEBKIT_EPOCH_OFFSET = 11_644_473_600
        CORE_DATA_EPOCH_OFFSET = 978_307_200

        def self.for(family, sqlite: Sqlite.new, plist: Plist.new)
          case family
          when "chromium" then Chromium.new(sqlite: sqlite)
          when "firefox" then Firefox.new(sqlite: sqlite)
          when "safari" then Safari.new(sqlite: sqlite, plist: plist)
          end
        end

        def self.row(kind, url, title: nil, folder: nil, visits: 1)
          { kind: kind, url: url.to_s, title: title.to_s.strip, folder: folder.to_s.strip,
            visits: [visits.to_i, 1].max }
        end

        # `History` (SQLite, copied first — Chrome keeps it locked) and
        # `Bookmarks` (plain JSON, read in place: it's rewritten whole, never
        # held open).
        class Chromium
          def initialize(sqlite:)
            @sqlite = sqlite
          end

          def history(profile, since:)
            return [] unless profile.history

            cutoff = (since.to_i + WEBKIT_EPOCH_OFFSET) * 1_000_000
            sql = "SELECT url, title, visit_count AS visits FROM urls WHERE last_visit_time >= #{cutoff}"
            @sqlite.with_copy(profile.history) { |query| query.call(sql) }
                   .map { |r| Readers.row("history", r["url"], title: r["title"], visits: r["visits"]) }
          end

          def bookmarks(profile)
            return [] unless profile.bookmarks

            data = JSON.parse(File.read(profile.bookmarks, encoding: "UTF-8"))
            Hash(data["roots"]).values.grep(Hash).flat_map { |node| walk(node, nil) }
          rescue JSON::ParserError
            []
          rescue Errno::EPERM, Errno::EACCES => e
            raise Sqlite::PermissionDenied, e.message
          end

          private

          def walk(node, folder)
            if node["type"] == "url"
              [Readers.row("bookmark", node["url"], title: node["name"], folder: folder)]
            else
              Array(node["children"]).flat_map { |child| walk(child, node["name"]) }
            end
          end
        end

        # `places.sqlite` holds both history and bookmarks — one copy, two
        # queries.
        class Firefox
          def initialize(sqlite:)
            @sqlite = sqlite
          end

          def history(profile, since:)
            return [] unless profile.history

            sql = "SELECT url, title, visit_count AS visits FROM moz_places " \
                  "WHERE last_visit_date >= #{since.to_i * 1_000_000}"
            @sqlite.with_copy(profile.history) { |query| query.call(sql) }
                   .map { |r| Readers.row("history", r["url"], title: r["title"], visits: r["visits"]) }
          end

          def bookmarks(profile)
            return [] unless profile.bookmarks

            sql = "SELECT p.url AS url, b.title AS title, f.title AS folder FROM moz_bookmarks b " \
                  "JOIN moz_places p ON p.id = b.fk LEFT JOIN moz_bookmarks f ON f.id = b.parent WHERE b.type = 1"
            @sqlite.with_copy(profile.bookmarks) { |query| query.call(sql) }
                   .map { |r| Readers.row("bookmark", r["url"], title: r["title"], folder: r["folder"]) }
          end
        end

        # `History.db` (SQLite) and `Bookmarks.plist` (binary plist). Both
        # sit under ~/Library/Safari, which macOS guards behind Full Disk
        # Access — a copy attempt without it raises Sqlite::PermissionDenied,
        # which Importer turns into an explanation, never a workaround.
        class Safari
          def initialize(sqlite:, plist:)
            @sqlite = sqlite
            @plist = plist
          end

          def history(profile, since:)
            return [] unless profile.history

            cutoff = since.to_i - CORE_DATA_EPOCH_OFFSET
            sql = "SELECT i.url AS url, v.title AS title, i.visit_count AS visits, MAX(v.visit_time) AS latest " \
                  "FROM history_items i JOIN history_visits v ON v.history_item = i.id " \
                  "WHERE v.visit_time >= #{cutoff} GROUP BY i.id"
            @sqlite.with_copy(profile.history) { |query| query.call(sql) }
                   .map { |r| Readers.row("history", r["url"], title: r["title"], visits: r["visits"]) }
          end

          def bookmarks(profile)
            return [] unless profile.bookmarks

            walk(@plist.read(profile.bookmarks), nil)
          end

          private

          def walk(node, folder)
            return [] unless node.is_a?(Hash)

            if node["URLString"]
              title = Hash(node["URIDictionary"])["title"]
              [Readers.row("bookmark", node["URLString"], title: title, folder: folder)]
            else
              Array(node["Children"]).flat_map { |child| walk(child, node["Title"]) }
            end
          end
        end

        # Reads a (binary or XML) plist: copies it into a private tmpdir,
        # converts the copy to XML with macOS's own `plutil`, parses it with
        # PlistXml, and deletes the copy.
        class Plist
          def initialize(command: "plutil")
            @command = command
          end

          def read(path)
            Dir.mktmpdir("portage-browser-import") do |dir|
              copy = File.join(dir, "copy.plist")
              copy_file(path, copy)
              PlistXml.parse(convert(copy))
            end
          end

          private

          def copy_file(path, copy)
            FileUtils.cp(path, copy)
          rescue Errno::EPERM, Errno::EACCES => e
            raise Sqlite::PermissionDenied, e.message
          end

          def convert(copy)
            out, err, status = Open3.capture3(@command, "-convert", "xml1", "-o", "-", copy)
            raise Sqlite::Unavailable, "plutil failed: #{err.strip}" unless status.success?

            out.dup.force_encoding("UTF-8").scrub
          rescue Errno::ENOENT
            raise Sqlite::Unavailable, "the plutil command isn't available (it ships with macOS)"
          end
        end
      end
    end
  end
end
