require "json"
require "fileutils"

module Portage
  module Cli
    # Remembers which origins answered `/.well-known/ucp` and which didn't.
    #
    # Without this, every URL-less search re-probes the same dozen hosts, and a
    # tool that fans out one unsolicited request per host per invocation is a
    # crawler wearing a CLI's clothes. Negative results are cached too — and
    # for longer — because "this shop doesn't speak UCP" is the answer that
    # would otherwise be re-asked most often and changes least.
    class ProbeCache
      PATH = File.join(Dir.home, ".portage", "discovery-cache.json").freeze
      HIT_TTL = 6 * 60 * 60
      MISS_TTL = 24 * 60 * 60

      def initialize(path: PATH, now: Time.now)
        @path = path
        @now = now.to_i
      end

      # @return [Boolean, nil] cached verdict, or nil when unknown/expired.
      def fetch(origin)
        entry = store[origin]
        return nil unless entry.is_a?(Hash) && entry.key?("ucp")

        ttl = entry["ucp"] ? HIT_TTL : MISS_TTL
        return nil if @now - entry["at"].to_i > ttl

        entry["ucp"]
      end

      def record(origin, ucp)
        store[origin] = { "ucp" => ucp, "at" => @now }
        write
        ucp
      end

      private

      def store
        @store ||= read
      end

      def read
        return {} unless File.readable?(@path)

        parsed = JSON.parse(File.read(@path))
        parsed.is_a?(Hash) ? parsed : {}
      rescue StandardError
        {}
      end

      # A cache that can't be written is a slow cache, never a failed run.
      def write
        FileUtils.mkdir_p(File.dirname(@path))
        File.write(@path, JSON.generate(@store))
      rescue StandardError
        nil
      end
    end
  end
end
