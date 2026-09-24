require "time"
require_relative "handoff_reconciler"
require_relative "handoff_wait_timeout"

module Portage
  module Cli
    # docs/plans/handoff-reconcile.md Phase 3 — `portage buy --wait`'s poll
    # loop. Polls a single pending shopper record through HandoffReconciler
    # with backoff (2s -> 30s, plus jitter) until it settles or its deadline
    # passes. Every decision about what a poll *means* stays
    # HandoffReconciler's; this only decides when to poll again and when to
    # stop.
    #
    # Ctrl-C: Ruby's default SIGINT handling raises Interrupt on the main
    # thread, most likely while this is asleep between polls. Caught here so
    # it never crashes the process with a backtrace — the record is already
    # pending in the transaction log either way (see the plan's
    # non-negotiable "the handoff itself never waits on reconcile"), so
    # there's nothing to undo. It's left exactly as it is for a later
    # `portage orders reconcile`; this never settles on interrupt.
    class HandoffWaiter
      INITIAL_BACKOFF = 2
      MAX_BACKOFF = 30

      def initialize(reconciler:, transaction_log:, wait_timeout_override: nil, clock: -> { Time.now },
                     sleeper: ->(seconds) { Kernel.sleep(seconds) })
        @reconciler = reconciler
        @transaction_log = transaction_log
        @wait_timeout_override = wait_timeout_override
        @clock = clock
        @sleeper = sleeper
      end

      # @param record [Hash] the pending TransactionLog record to poll —
      #   typically fresh from the same log this was built with.
      # @yield [Symbol, HandoffReconciler::Result] `:status` on every
      #   store-reported checkout status change (never on the first poll's
      #   initial status), `:settled` exactly once, when the loop ends
      #   because the record actually settled (never on a timeout or
      #   interrupt).
      # @return [HandoffReconciler::Result] the last poll's result — settled
      #   if it settled, otherwise still pending (deadline reached or
      #   interrupted).
      def call(record, &on_event)
        deadline = compute_deadline(record)
        backoff = INITIAL_BACKOFF
        last_checkout_status = nil
        loop do
          current = @transaction_log.find(record["idempotency_key"]) || record
          result = @reconciler.call(current)
          last_checkout_status = emit_status(result, last_checkout_status, on_event)
          return emit_settled(result, on_event) if result.settled
          return result if @clock.call >= deadline

          @sleeper.call(backoff_with_jitter(backoff))
          backoff = [backoff * 2, MAX_BACKOFF].min
        end
      rescue Interrupt
        HandoffReconciler::Result.new(idempotency_key: record["idempotency_key"], settled: false, status: "pending",
                                      note: "wait interrupted")
      end

      private

      def emit_status(result, last_checkout_status, on_event)
        return last_checkout_status unless result.checkout_status && result.checkout_status != last_checkout_status

        on_event&.call(:status, result)
        result.checkout_status
      end

      def emit_settled(result, on_event)
        on_event&.call(:settled, result)
        result
      end

      # The earlier of `handoff_wait_timeout` (default 30m, `off` removes
      # it) and the checkout's own `expires_at`. If somehow neither is set
      # (no expires_at on the record, and the timeout resolved to nil), the
      # default timeout still applies as a floor — this loop must not spin
      # forever with no deadline at all.
      def compute_deadline(record)
        started = @clock.call
        timeout = HandoffWaitTimeout.resolve(override: @wait_timeout_override)
        candidates = [(started + timeout if timeout), expires_at(record)].compact
        candidates.min || (started + HandoffWaitTimeout::DEFAULT)
      end

      def expires_at(record)
        value = record["expires_at"]
        return nil unless value

        Time.parse(value)
      rescue ArgumentError, TypeError
        nil
      end

      def backoff_with_jitter(backoff)
        backoff + Random.rand(backoff * 0.25)
      end
    end
  end
end
