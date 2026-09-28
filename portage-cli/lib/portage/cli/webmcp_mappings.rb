require "json"
require "fileutils"
require "time"

module Portage
  module Cli
    # Confirmed Phase 2 `tool_names:` mappings — `~/.portage/webmcp_mappings.json`
    # (docs/plans/webmcp-universal-outbound.md) — keyed by the page's tool
    # fingerprint (`Portage::Ucp::WebMcp::Fingerprint.for`: sorted tool names
    # plus a hash of each one's own input schema), never by origin
    # (decision 3): once a shopper confirms a mapping for one store, any
    # other store whose WebMCP tools have the exact same shape reuses it
    # with no prompt at all — in effect a local preset. A lookalike page
    # whose schemas differ even slightly gets a different fingerprint and
    # has to be confirmed again, so it can't borrow a mapping with a
    # different shape underneath the same tool names.
    #
    # Same "absent file or absent key means unset, a corrupt file raises
    # rather than silently falling back" posture as Config — this is
    # deliberately its own file, not a key under config.json, since it's
    # confirmed data (grows with use) rather than a standing preference.
    class WebmcpMappings
      PATH = File.join(Dir.home, ".portage", "webmcp_mappings.json").freeze

      def self.load(path: PATH) = new(path: path, data: read(path))

      def initialize(path: PATH, data: {})
        @path = path
        @data = data
      end

      # @param tools [Array<Hash>] the page's tools, as list_tools returns
      #   them.
      # @return [Hash{String => String}, nil] the confirmed tool_names: for
      #   this exact fingerprint, or nil when none has been confirmed yet.
      def lookup(tools)
        entry = @data[fingerprint_for(tools)]
        entry && entry["tool_names"].transform_keys(&:to_s)
      end

      # @param tool_names [Hash] action => tool name, as just confirmed.
      #   Merged onto whatever this fingerprint already had (so confirming a
      #   new action later doesn't drop an earlier one), never replaced
      #   outright.
      # @param origin [String, nil] recorded as metadata only — the lookup
      #   key is the fingerprint alone (decision 3), never the origin.
      # @return [Hash{String => String}] the fingerprint's tool_names: after
      #   merging.
      def confirm!(tools, tool_names:, origin: nil)
        key = fingerprint_for(tools)
        entry = @data[key] || { "tool_names" => {}, "origins" => [] }
        entry["tool_names"] = entry["tool_names"].merge(tool_names.transform_keys(&:to_s))
        entry["origins"] = (entry["origins"] + [origin]).compact.uniq if origin
        entry["confirmed_at"] = Time.now.utc.iso8601
        @data[key] = entry
        write
        entry["tool_names"]
      end

      def to_h = @data.dup

      def self.read(path)
        return {} unless File.readable?(path)

        raw = File.read(path)
        return {} if raw.empty?

        parsed = JSON.parse(raw)
        parsed.is_a?(Hash) ? parsed : {}
      end
      private_class_method :read

      private

      def fingerprint_for(tools) = Portage::Ucp::WebMcp::Fingerprint.for(tools)

      def write
        FileUtils.mkdir_p(File.dirname(@path))
        File.write(@path, JSON.pretty_generate(@data))
        File.chmod(0o600, @path)
      end
    end
  end
end
