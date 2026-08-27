module Portage
  module Ucp
    module Support
      # Bounded exponential backoff + jitter around a single upstream call.
      #
      # #with_retry is only ever safe to wrap around a call that is either
      # naturally idempotent (a read) or already sitting inside a
      # Support::Idempotency#dedup block (a mutation memoized by
      # idempotency_key) — every bundled adapter's mutating method already
      # dedups, so its Client-level HTTP/GraphQL calls satisfy this by
      # construction. Retrying a non-idempotent mutation that ISN'T inside
      # dedup can double it up: a request that partially applied upstream
      # before the connection dropped gets reapplied on retry. Never call
      # #with_retry around a bare mutation outside dedup.
      #
      # Only retries signals that mean "the upstream didn't do the work, try
      # again": HTTP 429 (honoring Retry-After when present), 5xx, and
      # platform-specific throttling (Shopify's GraphQL THROTTLED code,
      # cartSubmitForCompletion's SubmitThrottled pollAfter) via
      # #retryable_error? overrides. Everything else — 4xx business
      # rejections, UserError, OutOfStockError, ConflictError — passes
      # straight through un-retried.
      module Retry
        DEFAULT_MAX_ATTEMPTS = 4
        DEFAULT_BASE_DELAY = 0.25
        DEFAULT_MAX_DELAY = 4.0

        private

        def with_retry(max_attempts: DEFAULT_MAX_ATTEMPTS, base_delay: DEFAULT_BASE_DELAY,
                       max_delay: DEFAULT_MAX_DELAY)
          attempt = 0

          begin
            attempt += 1
            yield
          rescue StandardError => e
            raise unless retryable_error?(e)
            raise if attempt >= max_attempts

            sleep(retry_delay(e, attempt, base_delay, max_delay))
            retry
          end
        end

        # Default covers the common REST shape: any error carrying a `status`
        # of 429 or 5xx (Support::ApiError-including errors all expose this).
        # Platform clients override to recognize signals with no HTTP status
        # of their own (e.g. a GraphQL THROTTLED extension code).
        def retryable_error?(error)
          error.respond_to?(:status) && (error.status == 429 || (500..599).cover?(error.status))
        end

        # Honors an upstream Retry-After (seconds) when the error carries
        # one; otherwise backs off exponentially with full jitter.
        def retry_delay(error, attempt, base_delay, max_delay)
          retry_after = error.respond_to?(:retry_after) ? error.retry_after : nil
          return [retry_after.to_f, 0].max if retry_after

          exponential = [base_delay * (2**(attempt - 1)), max_delay].min
          rand * exponential
        end
      end
    end
  end
end
