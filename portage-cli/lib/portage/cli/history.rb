require "json"
require "fileutils"
require "securerandom"

module Portage
  module Cli
    # Local record of what `portage` has searched for and bought, entirely
    # separate from ProbeCache (which remembers *hosts*, not *actions*). Two
    # append-only, size-capped lists — purchases and searches — so `portage
    # history list` can answer "what did I already look for" and "what did I
    # already buy" without re-running anything, and `portage history clear`
    # can wipe either or both.
    #
    # A purchase entry is one checkout `portage buy` created, whatever came
    # of it: `outcome` is the report's own (`purchased`, `dry_run`,
    # `policy_blocked`, ...), so "what did I already buy" is the entries
    # whose outcome is `purchased`, and every other entry still carries the
    # `checkout_url` to finish it by hand. Entries written before `outcome`
    # existed have only `checkout_status` and `message`.
    class History
      PATH = File.join(Dir.home, ".portage", "history.json").freeze
      MAX_ENTRIES = 200

      def initialize(path: PATH, now: Time.now)
        @path = path
        @now = now.to_i
      end

      # @param items [Array<Hash>] what the checkout holds (`id`, `title`,
      #   `quantity`), not the search results it was picked from.
      # @param total [Integer, nil] minor units of `currency`.
      # rubocop:disable Metrics/ParameterLists -- all keywords; one entry's fields
      def record_purchase(url:, query:, outcome:, message:, source: nil, checkout_id: nil, checkout_status: nil,
                          checkout_url: nil, total: nil, currency: nil, items: [])
        # rubocop:enable Metrics/ParameterLists
        append("purchases", { "url" => url, "query" => query, "outcome" => outcome, "source" => source,
                              "checkout_id" => checkout_id, "checkout_status" => checkout_status,
                              "checkout_url" => checkout_url, "total" => total, "currency" => currency,
                              "items" => items, "message" => message, "at" => @now })
      end

      # @param url [String, nil] the store, for a `portage buy` that never
      #   reached a checkout there; nil for a cross-store `portage find`.
      # @param offers [Array<Hash>] a `find`'s (or `compare`'s) offers, kept
      #   so `portage buy --offer REF` can resolve an `offer_ref` later (see
      #   #offer). A search that keeps offers also gets a `search_id`, which
      #   `portage pick --search` names it by (docs/plans/
      #   human-pick-and-approve.md Phase 2).
      # @return [Hash] the saved entry.
      def record_search(query:, offer_count:, message:, url: nil, offers: [])
        kept = offers.empty? ? nil : saved_offers(offers)
        append("searches", { "search_id" => kept && "se_#{SecureRandom.hex(4)}", "query" => query, "url" => url,
                             "offer_count" => offer_count, "message" => message, "offers" => kept,
                             "at" => @now }.compact)
      end

      # @param id [String, nil] a `search_id`, or nil/"LAST" for the most
      #   recent search that kept offers.
      # @return [Hash, nil]
      def search(id = nil)
        with_offers = store["searches"].select { |search| Array(search["offers"]).any? }
        return with_offers.last if id.nil? || id.casecmp?("last")

        with_offers.reverse.find { |search| search["search_id"] == id }
      end

      # @return [Hash, nil] the saved offer for `ref` (store, product_id,
      #   title, amount, currency, url, checkout, found_at) plus the catalog
      #   `query` to buy it with — the offer's own when it was saved with
      #   one (a compare result, searched by the compared product's title),
      #   else that of the search that found it — from the most recent
      #   search that holds it.
      def offer(ref)
        store["searches"].reverse_each do |search|
          found = Array(search["offers"]).find { |saved| saved["offer_ref"] == ref }
          return { "query" => search["query"] }.merge(found) if found
        end
        nil
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

      # Takes a report's symbol-keyed offers or already-saved string-keyed
      # ones (`pick` re-saves the offer it compared alongside the results).
      def saved_offers(offers)
        offers.map do |offer|
          offer = offer.transform_keys(&:to_s)
          saved = { "offer_ref" => offer["offer_ref"], "store" => offer["store"], "product_id" => offer["product_id"],
                    "title" => offer["title"], "amount" => offer["amount"], "currency" => offer["currency"],
                    "url" => offer["url"], "checkout" => offer["checkout"], "found_at" => offer["found_at"] || @now }
          offer["query"] ? saved.merge("query" => offer["query"]) : saved
        end
      end

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
