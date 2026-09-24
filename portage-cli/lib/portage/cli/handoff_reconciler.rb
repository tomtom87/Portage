require "time"
require "uri"
require "portage/ucp"
require "portage/ucp/client"
require "portage/ucp/journal"
require_relative "user_agent"
require_relative "homepage_fetch"
require_relative "handoff_spend_mode"
require_relative "notifier"
require_relative "permissive_authenticator"
require_relative "handoff_reconciler/wire_adapters"

module Portage
  module Cli
    # docs/plans/handoff-reconcile.md Phase 1 — resolves a single pending
    # `settled_by: "shopper"` TransactionLog record: did the shopper finish
    # the checkout `portage buy` handed them, in the browser, on their own?
    #
    # Never infers success from a vanished checkout, a 404, or a plain
    # expiry with no answer — those settle `failed` with `resolution:
    # "unknown"`/`"expired"`, never `complete`. Only a `completed` status the
    # store itself reports settles `complete`. Idempotent: a record that's
    # already terminal (`complete`/`failed`) is a no-op, so `portage buy
    # --wait` and a cron `portage orders reconcile` racing each other never
    # double-settle.
    class HandoffReconciler
      # Raised when the store can't be reached again at all (no native UCP
      # manifest, no matching/configured platform adapter) — the record
      # stays pending; a later run (or a shorter-lived credential/env
      # problem being fixed) may still resolve it.
      class ReconnectError < StandardError; end

      Result = Struct.new(:idempotency_key, :settled, :status, :resolution, :order_id, :amount, :currency, :note,
                          keyword_init: true) do
        def to_h
          { idempotency_key: idempotency_key, settled: settled, status: status, resolution: resolution,
            order_id: order_id, amount: amount, currency: currency, note: note }.compact
        end
      end

      # @param spend_mode [String] one of HandoffSpendMode::MODES — Phase 2.
      def initialize(transaction_log: Portage::Ucp::Support::TransactionLog.new,
                     order_ledger: Portage::Ucp::Support::OrderLedger.new,
                     journal: Portage::Ucp::Journal::PurchaseJournal.new,
                     notifier: Notifier.new, spend_mode: HandoffSpendMode.resolve, clock: -> { Time.now })
        @transaction_log = transaction_log
        @order_ledger = order_ledger
        @journal = journal
        @notifier = notifier
        @spend_mode = spend_mode
        @clock = clock
      end

      # @param record [Hash] a TransactionLog record, as returned by
      #   `#find`/`#all` — expected to have `settled_by: "shopper"`, but
      #   this checks rather than assumes (see .each_pending_shopper_record).
      # @return [Result]
      def call(record)
        if terminal?(record)
          return Result.new(idempotency_key: record["idempotency_key"], settled: false, status: record["status"],
                            note: "already settled")
        end
        unless record["settled_by"] == "shopper"
          return Result.new(idempotency_key: record["idempotency_key"], settled: false,
                            note: "not a shopper handoff")
        end

        reconcile(record)
      end

      # Every `pending`, `settled_by: "shopper"` record in the log — what
      # `portage orders reconcile` (no `--checkout`) iterates.
      def self.each_pending_shopper_record(transaction_log)
        return enum_for(:each_pending_shopper_record, transaction_log) unless block_given?

        transaction_log.each_record do |record|
          yield record if record["settled_by"] == "shopper" && record["status"] == "pending"
        end
      end

      private

      def terminal?(record) = Portage::Ucp::Support::TransactionLog::TERMINAL_STATUSES.include?(record["status"])

      def reconcile(record)
        session = reconnect(record["store_url"])
        checkout = session.get_checkout(checkout_id: record["checkout_id"])
        settle_from_checkout(record, checkout)
      rescue StandardError => e
        # A reconnect failure (no automated path back into the store) and a
        # transport error mid-call are both treated exactly like "not
        # found" — see the class comment and the plan's outcome table.
        # Distinguishing a 404 from a timeout from "can't reconnect at all"
        # buys nothing here: either way, this run learned nothing new about
        # whether the shopper paid, and the record's own `expires_at` is
        # still the only thing allowed to turn that into a settle.
        settle_not_found(record, note: e.message)
      end

      def settle_from_checkout(record, checkout)
        case checkout && checkout["status"]
        when "completed" then settle_complete(record, checkout)
        when "canceled" then settle_failed(record, resolution: nil)
        when nil then settle_not_found(record)
        else
          past_expiry?(record) ? settle_failed(record, resolution: "expired") : still_pending(record)
        end
      end

      def settle_not_found(record, note: nil)
        return still_pending(record, note: note) unless past_expiry?(record)

        settle_failed(record, resolution: "unknown", note: note)
      end

      def past_expiry?(record)
        expires_at = record["expires_at"]
        return false unless expires_at

        Time.parse(expires_at) < @clock.call
      rescue ArgumentError
        false
      end

      def still_pending(record, note: nil)
        Result.new(idempotency_key: record["idempotency_key"], settled: false, status: "pending", note: note)
      end

      def settle_failed(record, resolution:, note: nil)
        updated = @transaction_log.complete(idempotency_key: record["idempotency_key"], status: "failed",
                                            resolution: resolution)
        notify(record, updated, result: "failed")
        Result.new(idempotency_key: record["idempotency_key"], settled: true, status: "failed",
                   resolution: resolution, note: note)
      end

      # The store's own reported amount, at settle time — not the
      # handoff-time snapshot on `record` (the shopper may have changed
      # quantity/shipping in the browser; see the plan's "Non-negotiable
      # constraints").
      def settle_complete(record, checkout)
        amount = Portage::Ucp::Support::Totals.amount(checkout["totals"])
        currency = checkout["currency"]
        counts = @spend_mode != "warn"

        updated = @transaction_log.complete(idempotency_key: record["idempotency_key"], status: "complete",
                                            amount: amount, currency: currency, counts_toward_caps: counts)

        order_id = record_order(record, checkout)
        record_journal(record, checkout)
        notify(record, updated, result: "complete", order_id: order_id)

        Result.new(idempotency_key: record["idempotency_key"], settled: true, status: "complete", order_id: order_id,
                   amount: amount, currency: currency)
      end

      # Never blocks the settle above on this — the transaction record is
      # already `complete` by the time this runs. A failure here just means
      # the order snapshot/journal entry didn't get written this round; the
      # money is still correctly recorded either way.
      def record_order(record, checkout)
        order = checkout["order"]
        return nil unless order && order["id"]

        session = reconnect(record["store_url"])
        order_wire = session.get_order(order_id: order["id"])
        return order["id"] unless order_wire

        @order_ledger.record(idempotency_key: record["idempotency_key"], order: WireOrder.new(order_wire))
        order["id"]
      rescue StandardError
        order["id"]
      end

      def record_journal(record, checkout)
        return unless @journal && checkout["order"]

        @journal.record_checkout(shop: record["shop"], source: "handoff_reconcile",
                                 checkout: WireCheckout.new(checkout), idempotency_key: record["idempotency_key"])
      rescue StandardError
        nil
      end

      # Best-effort, same posture as Buy#hand_off's own notifier call — a
      # failed webhook POST never raises out of #call/#reconcile.
      def notify(record, updated, result:, order_id: nil)
        payload = { event: "checkout_reconciled", result: result, reason: record["handoff_reason"],
                    checkout_id: record["checkout_id"], shop: record["shop"], store_url: record["store_url"],
                    amount: updated["amount"], currency: updated["currency"], order_id: order_id,
                    resolution: updated["resolution"] }
        if result == "complete" && record["handoff_reason"] == "policy_blocked" &&
           @spend_mode != "warn"
          payload[:cap_overridden_by_shopper] =
            true
        end
        @notifier.call(payload.compact)
      rescue StandardError
        nil
      end

      # --- reconnecting to the store (see the plan's "Reconciling needs the
      # store again") ---

      def reconnect(store_url)
        raise ReconnectError, "no store_url on this record" if store_url.to_s.empty?

        uri = URI.parse(store_url)
        native_session(uri) || adapter_session(uri) ||
          raise(ReconnectError, "no automated path back into #{store_url}")
      end

      def native_session(uri)
        Portage::Ucp::Client.discover(uri.to_s, headers: UserAgent.headers)
      rescue Portage::Ucp::Client::DiscoveryError
        nil
      end

      # Mirrors Buy's own own-store loopback fallback (#adapter_flow) — a
      # later process re-discovers the platform from the homepage the same
      # way, and must not assume the original process's session or
      # credentials still exist, only that this platform's env vars are
      # still set (see the plan's non-negotiable constraint).
      def adapter_session(uri)
        body, headers = HomepageFetch.call(uri)
        platform = body && Portage::Ucp::Resolver.detect_platform(body, headers)
        return nil unless platform

        env = Portage::Ucp::Resolver.env_for(platform)
        return nil unless Portage::Ucp::Resolver.missing_env(platform, env).empty?

        adapter = Portage::Ucp::Resolver.build_adapter(platform, env)
        Portage::Ucp::Client.for_adapter(adapter, authenticator: PermissiveAuthenticator.new)
      rescue StandardError
        nil
      end
    end
  end
end
