require "json"
require "fileutils"

module Portage
  module Cli
    # Local record of what `portage` has searched for and bought, entirely
    # separate from ProbeCache (which remembers *hosts*, not *actions*). Two
    # append-only, size-capped lists — purchases and searches — so `portage
    # history list` can answer "what did I already look for" and "what did I
    # already buy" without re-running anything, and `portage history clear`
    # can wipe either or both.
    class History
      PATH = File.join(Dir.home, ".portage", "history.json").freeze
      MAX_ENTRIES = 200

      def initialize(path: PATH, now: Time.now)
        @path = path
        @now = now.to_i
      end

      def record_purchase(url:, query:, checkout:, message:, checkout_status: nil, products: [])
        append("purchases", { "url" => url, "query" => query, "checkout" => checkout,
                              "checkout_status" => checkout_status, "message" => message,
                              "products" => products, "at" => @now })
      end

      def record_search(query:, offer_count:, message:)
        append("searches", { "query" => query, "offer_count" => offer_count, "message" => message, "at" => @now })
      end

      def purchases(limit: MAX_ENTRIES) = store["purchases"].last(limit)

      def searches(limit: MAX_ENTRIES) = store["searches"].last(limit)

      # @param kind [String, nil] "purchases", "searches", or nil for both.
      def clear(kind: nil)
        kinds = kind ? [kind] : %w[purchases searches]
        kinds.each { |k| store[k] = [] }
        write
      end

      private

      def append(kind, entry)
        store[kind] = (store[kind] + [entry]).last(MAX_ENTRIES)
        write
        entry
      end

      def store
        @store ||= read
      end

      def read
        parsed = File.readable?(@path) ? JSON.parse(File.read(@path)) : {}
        parsed = {} unless parsed.is_a?(Hash)
        { "purchases" => Array(parsed["purchases"]), "searches" => Array(parsed["searches"]) }
      rescue StandardError
        { "purchases" => [], "searches" => [] }
      end

      # A history that can't be written just doesn't remember this run —
      # never a failed buy or search.
      def write
        FileUtils.mkdir_p(File.dirname(@path))
        File.write(@path, JSON.generate(@store))
      rescue StandardError
        nil
      end
    end
  end
end
