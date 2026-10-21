require "time"
require "uri"
require "portage/ucp"
require "portage/ucp/journal"
require_relative "history"

module Portage
  module Cli
    # `portage orders list` — the shopper's purchases, merged from the three
    # local records none of which is a full order on its own (docs/plans/
    # buyer-mcp-server.md Phase 1): the journal (what was bought, per line
    # item), the order ledger (permalink and adjustments, keyed by order id)
    # and CLI history (hand-offs and store URLs that never reached a journal
    # row). Read-only, and nothing is backfilled: an entry says which record
    # it came from (`source`), so a gap shows rather than being papered over.
    #
    # A history entry carries a `checkout_id`, not an order id; the
    # TransactionLog record for that checkout carries the `idempotency_key`
    # the journal rows were written under. That is the link used to drop a
    # history purchase the journal already covers, and to recognise a
    # hand-off (a transaction `settled_by: "shopper"`).
    class OrderHistory
      def initialize(journal: Portage::Ucp::Journal::PurchaseJournal.new,
                     order_ledger: Portage::Ucp::Support::OrderLedger.new,
                     history: History.new, transaction_log: Portage::Ucp::Support::TransactionLog.new)
        @journal = journal
        @order_ledger = order_ledger
        @history = history
        @transaction_log = transaction_log
      end

      # @param query [String, nil] case-insensitive; matches shop host,
      #   product id, item title and order id.
      # @param limit [Integer, nil] applied after filtering and sorting.
      # @return [Array<Hash>] newest first.
      def call(query: nil, limit: nil)
        rows = @journal.all
        transactions = transactions_by_checkout
        entries = journal_entries(rows, transactions) + history_only_entries(rows, transactions)
        entries = entries.sort_by { |entry| entry["recorded_at"] }.reverse
        entries = entries.select { |entry| matches?(entry, query.downcase) } if query && !query.empty?
        limit ? entries.first(limit) : entries
      end

      private

      # A record without a checkout id links to no history entry.
      def transactions_by_checkout
        @transaction_log.each_record.select { |record| record["checkout_id"] }
                                    .to_h { |record| [record["checkout_id"], record] }
      end

      def journal_entries(rows, transactions)
        by_key = history_by_key(transactions)
        rows.group_by { |row| row["order_id"] || row["idempotency_key"] }.map do |order_id, group|
          first = group.first
          titles = item_titles(by_key[first["idempotency_key"]])
          items = group.map do |row|
            { "product_id" => row["product_id"], "title" => titles[row["product_id"]],
              "quantity" => row["quantity"], "amount" => row["amount"] }
          end
          journal_entry(order_id, first, items)
        end
      end

      def journal_entry(order_id, first, items)
        order = ledger_order(first["order_id"])
        { "source" => "journal", "order_id" => first["order_id"] || order_id, "shop" => first["shop"],
          "recorded_at" => first["recorded_at"], "currency" => first["currency"],
          "total" => items.filter_map { |item| item["amount"] }.then { |amounts| amounts.sum unless amounts.empty? },
          "items" => items, "permalink_url" => order["permalink_url"], "adjustments" => order["adjustments"] || [] }
      end

      def ledger_order(order_id)
        record = @order_ledger.find(order_id) if order_id
        record&.fetch("order", nil) || {}
      end

      # Purchases and hand-offs no journal row covers.
      def history_only_entries(rows, transactions)
        covered = rows.to_set { |row| row["idempotency_key"] }
        @history.purchases.filter_map do |purchase|
          transaction = transactions[purchase["checkout_id"]]
          next if transaction && covered.include?(transaction["idempotency_key"])
          next unless purchase["outcome"] == "purchased" || transaction&.fetch("settled_by", nil) == "shopper"

          history_entry(purchase)
        end
      end

      def history_entry(purchase)
        { "source" => "history", "order_id" => nil, "shop" => host_of(purchase["url"]),
          "recorded_at" => Time.at(purchase["at"]).utc.iso8601, "currency" => purchase["currency"],
          "total" => purchase["total"], "outcome" => purchase["outcome"], "checkout_url" => purchase["checkout_url"],
          "items" => Array(purchase["items"]).map do |item|
            { "product_id" => item["id"], "title" => item["title"], "quantity" => item["quantity"] }
          end,
          "permalink_url" => nil, "adjustments" => [] }
      end

      # idempotency_key => the history purchase made under it, so a journal
      # order can borrow the item titles history kept (the journal has none).
      def history_by_key(transactions)
        @history.purchases.each_with_object({}) do |purchase, by_key|
          key = transactions[purchase["checkout_id"]]&.fetch("idempotency_key", nil)
          by_key[key] = purchase if key
        end
      end

      def item_titles(purchase)
        Array(purchase&.fetch("items", nil)).to_h { |item| [item["id"], item["title"]] }
      end

      def host_of(url)
        URI.parse(url.to_s).host
      rescue URI::InvalidURIError
        nil
      end

      def matches?(entry, query)
        fields = [entry["shop"], entry["order_id"]] +
                 entry["items"].flat_map { |item| [item["product_id"], item["title"]] }
        fields.compact.any? { |field| field.to_s.downcase.include?(query) }
      end
    end
  end
end
