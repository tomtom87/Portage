require "timeout"
require "net/http"

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

      # Raised when the confirm or status HTTP call itself fails (non-2xx,
      # not the 409 Support::HttpClient already normalizes to ConflictError)
      # — a transport failure talking to the out-of-band approver, not a
      # denial by it. Kept distinct from ConfirmationDeniedError: that one
      # means "someone said no" or "no one answered in time," this one means
      # "couldn't even ask."
      class WebhookApiError < Portage::Ucp::Error
        include Support::ApiError

        private

        def api_label
          "Confirmer::Webhook"
        end
      end

      # Out-of-band approval over plain HTTP: POST the request, then poll a
      # status endpoint until the out-of-band channel (Slack, WhatsApp,
      # whatever a caller wires up) records an answer. Core only ever speaks
      # HTTP here — the actual notification transport is the caller's job,
      # same "transport-agnostic by design" posture as this module's
      # top-of-file comment.
      #
      # Deliberately its own timeout default, not Terminal::
      # DEFAULT_TIMEOUT_SECONDS: 120s fits a human already at a keyboard, not
      # someone who has to notice a Slack message and tap approve.
      class Webhook
        include Support::HttpClient

        DEFAULT_TIMEOUT_SECONDS = 900
        DEFAULT_POLL_INTERVAL_SECONDS = 5

        # @param confirm_url [String] posted `{amount, currency, merchant,
        #   idempotency_key}` once, to kick off the out-of-band approval.
        # @param status_url [String] polled (GET, `?idempotency_key=...`)
        #   for `{"status" => "approved" | "denied" | "pending"}` until it
        #   stops answering "pending" or `timeout_seconds` elapses.
        # @param wait [#call, nil] escape hatch for push-based transports —
        #   when given, called with `idempotency_key` instead of polling,
        #   and must itself return `"approved"` or `"denied"` (blocking as
        #   long as it needs to; `timeout_seconds` isn't enforced around it,
        #   since a push transport is expected to enforce its own).
        def initialize(confirm_url:, status_url:, timeout_seconds: DEFAULT_TIMEOUT_SECONDS,
                       poll_interval_seconds: DEFAULT_POLL_INTERVAL_SECONDS, headers: {}, wait: nil)
          @confirm_url = confirm_url
          @status_url = status_url
          @timeout_seconds = timeout_seconds
          @poll_interval_seconds = poll_interval_seconds
          @headers = headers
          @wait = wait
        end

        # @raise [Portage::Ucp::ConfirmationDeniedError] on an explicit
        #   deny, or on timeout (fail-closed, same as Terminal).
        # @raise [Portage::Ucp::Confirmer::WebhookApiError] if the confirm
        #   or status HTTP call itself fails.
        # @return [Hash] `{approved: true}` on approval.
        def confirm!(amount:, currency:, merchant:, idempotency_key:)
          json_request(Net::HTTP::Post, @confirm_url, route: :notify,
                                                      body: { amount: amount, currency: currency, merchant: merchant,
                                                              idempotency_key: idempotency_key },
                                                      headers: @headers)

          status = @wait ? @wait.call(idempotency_key) : poll(idempotency_key)
          return { approved: true } if status == "approved"

          deny!(status == "denied" ? :denied : :timeout, idempotency_key)
        end

        private

        def poll(idempotency_key)
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @timeout_seconds

          loop do
            response = json_request(Net::HTTP::Get, status_url_for(idempotency_key), route: :notify, headers: @headers)
            return response["status"] if %w[approved denied].include?(response["status"])
            return "timeout" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

            sleep(@poll_interval_seconds)
          end
        end

        def status_url_for(idempotency_key)
          uri = URI(@status_url)
          uri.query = "idempotency_key=#{URI.encode_www_form_component(idempotency_key)}"
          uri
        end

        def deny!(reason, idempotency_key)
          message = reason == :timeout ? "confirmation timed out after #{@timeout_seconds}s" : "confirmation denied"
          raise Portage::Ucp::ConfirmationDeniedError.new(
            message, reason: reason, decision: { approved: false, reason: reason, idempotency_key: idempotency_key }
          )
        end

        def api_error_class
          WebhookApiError
        end
      end
    end
  end
end
