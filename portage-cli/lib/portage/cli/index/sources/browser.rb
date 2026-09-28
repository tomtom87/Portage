module Portage
  module Cli
    module Index
      module Sources
        # A pointer, not a reader. Browser-derived entries come from
        # `portage browser import` (BrowserImport::Importer, Phase 3), which
        # writes them straight into Index::Store — `sources: ["history"]`/
        # `["bookmark"]` — only after the user has seen the list and
        # approved it. `index build` must never read a browser's history on
        # its own (that would skip the approval), so this source yields
        # nothing and isn't in Sources::DEFAULT_NAMES; it stays in the
        # registry so `portage index sources` still says where browser
        # entries come from.
        class Browser
          def name = "browser"

          def description
            "Bookmarks/history shop domains — written by `portage browser import` after you approve the list " \
              "(never read by `index build` itself). Yields nothing here."
          end

          def source_path = nil

          # `**` accepts (and ignores) the shared Source#candidates(queries:)
          # interface.
          def candidates(**) = []
        end
      end
    end
  end
end
