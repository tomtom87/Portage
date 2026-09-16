require "portage/ucp"
require "portage/ucp/journal"

module Portage
  module Cli
    # Read-only REPL helpers over the three local stores design-log §22
    # names (`TransactionLog`, `OrderLedger`, `PurchaseJournal`) — the
    # console remainder of item 6. Deliberately a REPL, not the web/admin
    # panel §16 also described: that panel needs its own session auth
    # because a browser is a new place for a token to leak, on a process
    # that already holds live platform admin credentials in its env. A
    # local REPL run by whoever already holds this machine's `~/.portage`
    # files and env has neither problem, so this is `exe/portage-console`
    # + IRB rather than a server. Every returned record still goes through
    # `Observability.redact` regardless — no new leak surface isn't the
    # same guarantee as never printing a secret.
    #
    # Each store defaults to its own real `~/.portage/*` file, injectable
    # (same posture as `Dispatcher`'s own `transaction_log:`/`order_ledger:`/
    # `journal:` kwargs) so a spec, or a REPL session pointed at a different
    # machine's exported files, doesn't have to touch the real ones.
    #
    # `journal` reads `~/.portage/journal.jsonl` and comes back empty unless
    # whatever built the `Dispatcher` for your purchases passed a `journal:`
    # (core's own default is `nil`) — `transactions`/`orders` don't have
    # that caveat, since `TransactionLog`/`OrderLedger` are Dispatcher's
    # un-opt-out-able defaults.
    #
    # @example
    #   require "portage/cli/console"
    #   include Portage::Cli::Console
    #   transactions(shop: "example.myshopify.com")
    module Console
      def transactions(shop: nil, transaction_log: Portage::Ucp::Support::TransactionLog.new)
        scope(transaction_log.all, shop: shop)
      end

      def find_transaction(idempotency_key, transaction_log: Portage::Ucp::Support::TransactionLog.new)
        redact(transaction_log.find(idempotency_key))
      end

      def transactions_since(since, shop:, transaction_log: Portage::Ucp::Support::TransactionLog.new)
        redact(transaction_log.completed_since(since, shop: shop))
      end

      def orders(order_ledger: Portage::Ucp::Support::OrderLedger.new)
        scope(order_ledger.all)
      end

      def find_order(order_id, order_ledger: Portage::Ucp::Support::OrderLedger.new)
        redact(order_ledger.find(order_id))
      end

      def journal(shop: nil, purchase_journal: Portage::Ucp::Journal::PurchaseJournal.new)
        scope(purchase_journal.all, shop: shop)
      end

      private

      def scope(records, shop: nil)
        records = records.select { |record| record["shop"] == shop } if shop
        redact(records)
      end

      def redact(records) = Portage::Ucp::Observability.redact(records)
    end
  end
end
