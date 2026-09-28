require "digest"
require "json"

module Portage
  module Ucp
    module WebMcp
      # A page's WebMCP tools, reduced to what identifies its *shape* rather
      # than any single store — shared by Presets.detect (Phase 1, name-only)
      # and portage-cli's confirmed-mapping store (Phase 2, name + schema).
      # Neither reads a tool's `description`: that's page text, and this
      # gem's whole trust posture (see Presets' module comment) is that page
      # text never decides a mapping — only what the page actually
      # registers.
      module Fingerprint
        # @param tools [Array<Hash>] as Bridge#list_tools/Transport#tools
        #   returns them (string- or symbol-keyed).
        # @return [Array<String>] tool names, sorted. What Presets.detect
        #   compares a preset's own fingerprint against — a platform's tool
        #   set is assumed stable enough that names alone are a safe key.
        def self.names(tools)
          tools.map { |tool| (tool["name"] || tool[:name]).to_s }.sort
        end

        # @return [String] a single digest of every tool's name *and* its
        #   own input schema — used to key a confirmed Phase 2 mapping
        #   (docs/plans/webmcp-universal-outbound.md decision 3), which is
        #   shared across origins with the exact same shape but must not be
        #   reused by a lookalike page whose schemas differ even though its
        #   tool names happen to match.
        def self.for(tools)
          parts = tools.map do |tool|
            name = (tool["name"] || tool[:name]).to_s
            schema = tool["inputSchema"] || tool[:inputSchema] || {}
            "#{name}:#{Digest::SHA256.hexdigest(JSON.generate(schema))}"
          end
          Digest::SHA256.hexdigest(parts.sort.join("|"))
        end
      end
    end
  end
end
