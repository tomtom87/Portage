require "json"

module Portage
  module Cli
    module Index
      module Sources
        # Phase 3 (browser import) hasn't shipped yet — this source reads
        # its eventual output file if present, and yields nothing
        # otherwise, so `portage index build` already knows how to pick up
        # browser-derived entries the moment that phase lands, with no
        # change needed here. Never reads a browser's history/bookmarks/
        # cookies/autofill store itself — that's Phase 3's job, gated by
        # its own opt-in `portage browser import` command.
        class Browser
          PATH = File.join(Dir.home, ".portage", "index", "browser-import.json").freeze

          def initialize(path: PATH)
            @path = path
          end

          def name = "browser"

          def description
            "Phase 3's browser-import output (not built yet) — reads #{@path} if present, yields nothing " \
              "otherwise."
          end

          def source_path = @path

          # `**` accepts (and ignores) the shared Source#candidates(queries:)
          # interface — a browser import has no query of its own to run.
          def candidates(**)
            return [] unless File.readable?(@path)

            data = JSON.parse(File.read(@path, encoding: "UTF-8"))
            Array(data["entries"]).filter_map { |entry| sighting_for(entry) }
          rescue StandardError
            []
          end

          private

          def sighting_for(entry)
            origin = entry["origin"]
            return nil unless origin

            { origin: origin, url: entry["url"], title: entry["title"], brand: nil, gtin: nil }
          end
        end
      end
    end
  end
end
