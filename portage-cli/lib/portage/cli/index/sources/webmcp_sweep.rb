module Portage
  module Cli
    module Index
      module Sources
        # Would detect each known origin's WebMCP preset by driving a
        # browser bridge against it (docs/plans/webmcp-universal-outbound.md)
        # — that bridge doesn't exist yet (it's Phase 6 here / WebMCP Phase
        # 3-4), so this source skips cleanly rather than failing: it's
        # listed by `portage index sources` so its eventual arrival is
        # discoverable, but `candidates` is always empty until a bridge is
        # wired in.
        class WebmcpSweep
          def name = "webmcp_sweep"

          def description
            "Detects a WebMCP preset per known origin via the browser bridge. No bridge is wired up yet " \
              "— skips cleanly, yields nothing."
          end

          def source_path = nil

          # `**` accepts (and ignores) the shared Source#candidates(queries:)
          # interface, since this source never runs a query of its own.
          def candidates(**) = []
        end
      end
    end
  end
end
