require "timeout"

module Portage
  module Ucp
    # Phase 3 (docs/plans/agentic-payments.md) — the last gate before a
    # payment-completing dispatch, run by Dispatcher right after PolicyGuard
    # passes. Transport-agnostic by design: Dispatcher only ever calls
    # `#confirm!(amount:, currency:, merchant:, idempotency_key:)` on
    # whatever object it's given, so a future WhatsApp/Slack confirmer is a
    # separate gem implementing the same method, no core change required.
    # `idempotency_key` rides along even though this phase's Terminal
    # implementation ignores it — an async transport needs it to bind a
    # reply back to the request that asked.
    module Confirmer
      # Blocks the CLI process on stdin: "Approve? [y/N]". Fail-closed — no
      # answer within `timeout_seconds` denies, same as an explicit "n",
      # never leaves a payment pending on an agent that's still waiting.
      # Checkout staleness while the operator was thinking isn't handled
      # here: the confirmed amount is re-validated by nothing in this class,
      # but the adapter call `call_adapter` makes right after this passes
      # hits the real backend, which is the thing that'd reject a checkout
      # that expired mid-wait — no separate re-check needed.
      class Terminal
        DEFAULT_TIMEOUT_SECONDS = 120

        def initialize(timeout_seconds: DEFAULT_TIMEOUT_SECONDS, input: $stdin, output: $stdout)
          @timeout_seconds = timeout_seconds
          @input = input
          @output = output
        end

        # @raise [Portage::Ucp::ConfirmationDeniedError] on "n", timeout, or
        #   EOF (stdin closed out from under a headless run) — anything that
        #   isn't an explicit "y" denies.
        # @return [Hash] `{approved: true}` on "y".
        def confirm!(amount:, currency:, merchant:, idempotency_key:)
          @output.print("Approve payment of #{amount} #{currency} to #{merchant.inspect}? [y/N] ")
          @output.flush

          answer = read_with_timeout
          return { approved: true } if answer&.strip&.downcase == "y"

          deny!(answer.nil? ? :timeout : :denied, idempotency_key)
        end

        private

        def read_with_timeout
          Timeout.timeout(@timeout_seconds) { @input.gets }
        rescue Timeout::Error
          nil
        end

        def deny!(reason, idempotency_key)
          message = reason == :timeout ? "confirmation timed out after #{@timeout_seconds}s" : "confirmation denied"
          raise Portage::Ucp::ConfirmationDeniedError.new(
            message, reason: reason, decision: { approved: false, reason: reason, idempotency_key: idempotency_key }
          )
        end
      end

      # Always approves. For adapter conformance suites and Dispatcher specs
      # that need a real `confirm!` call to return without blocking on
      # stdin — never wire this into a real Dispatcher: confirmation
      # defaulting to *on* is the thing that makes Phase 1's permanently-
      # spendable stored token safe (see plan, "No arm step").
      class AutoApprove
        def confirm!(**)
          { approved: true }
        end
      end
    end
  end
end
