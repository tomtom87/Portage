require "json"

module Portage
  module Cli
    module Index
      # Moves a pre-SQLite stores.json/products.json into an Index::Database
      # (docs/plans/local-catalogue.md Phase 1): every object entry, in one
      # transaction, then the file is renamed to *.json.migrated. Nothing
      # is ever deleted, and an unreadable or non-object file is left
      # untouched. Index::Database runs this only on the open that creates
      # the database, so it happens at most once.
      class LegacyImport
        # @return [Array<String>] the legacy json files present in `dir`.
        def self.files(dir)
          Database::TABLES.keys.map { |table| File.join(dir, "#{table}.json") }.select { |file| File.file?(file) }
        end

        def initialize(database, dir)
          @database = database
          @dir = dir
        end

        def call
          self.class.files(@dir).each do |file|
            entries = read(file)
            next unless entries

            @database.transaction do
              entries.each { |key, entry| @database.put(File.basename(file, ".json"), key, entry) if entry.is_a?(Hash) }
            end
            rename(file)
          end
        end

        private

        def read(file)
          parsed = JSON.parse(File.read(file, encoding: "UTF-8"))
          parsed.is_a?(Hash) ? parsed : nil
        rescue JSON::ParserError, SystemCallError
          nil
        end

        # The rows are already committed, so a rename that fails must not
        # fail the open — the file is just left where it was.
        def rename(file)
          File.rename(file, "#{file}.migrated")
        rescue SystemCallError
          nil
        end
      end
    end
  end
end
