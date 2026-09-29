require "json"
require "fileutils"
require "securerandom"

module Portage
  module Cli
    # Local record of the priced checkouts `portage buy --dry-run` has shown,
    # one JSON file per quote under ~/.portage/quotes/. A quote is what
    # `buy --quote QUOTE_ID --yes` later buys: it pins the store, product,
    # quantity and the total that was shown, so the run that charges can
    # refuse if the price has moved since (see Cli.buy_from_quote).
    #
    # Quotes never expire. Each is single use: #consume stamps `used_at`
    # rather than deleting the file, so a spent quote is still told apart
    # from one that never existed.
    class Quotes
      DIR = File.join(Dir.home, ".portage", "quotes").freeze
      ID_FORMAT = /\Aqt_[0-9a-f]{12}\z/

      def initialize(dir: DIR, now: Time.now)
        @dir = dir
        @now = now.to_i
      end

      # @param total [Integer, nil] minor units of `currency`.
      # @return [Hash, nil] the saved quote (string keys, `quote_id` set), or
      #   nil when it couldn't be written — a quote that can't be saved just
      #   isn't offered, never a failed dry run.
      def create(store:, product_id:, qty:, total:, currency:, query: nil, offer_ref: nil)
        quote = { "quote_id" => "qt_#{SecureRandom.hex(6)}", "offer_ref" => offer_ref, "store" => store,
                  "product_id" => product_id, "query" => query, "qty" => qty, "total" => total,
                  "currency" => currency, "created_at" => @now, "approved" => false }
        write(quote)
      end

      # @return [Hash, nil] nil for an unknown (or malformed) id.
      def find(quote_id)
        return nil unless quote_id.to_s.match?(ID_FORMAT)

        parsed = JSON.parse(File.read(path(quote_id)))
        parsed if parsed.is_a?(Hash)
      rescue StandardError
        nil
      end

      # Marks the quote spent. Best-effort, like every other local record.
      def consume(quote_id)
        quote = find(quote_id)
        write(quote.merge("used_at" => @now)) if quote
      end

      private

      def path(quote_id) = File.join(@dir, "#{quote_id}.json")

      def write(quote)
        FileUtils.mkdir_p(@dir)
        File.write(path(quote["quote_id"]), JSON.generate(quote))
        quote
      rescue StandardError
        nil
      end
    end
  end
end
