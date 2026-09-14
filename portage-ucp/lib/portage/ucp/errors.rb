module Portage
  module Ucp
    class Error < StandardError; end
    class NotImplementedError < Error; end
    class UnknownCapabilityError < Error; end
    class UnknownActionError < Error; end
    class CapabilityNotAdvertisedError < Error; end
    class AuthenticationError < Error; end
    class RawPanRejectedError < Error; end
    class RateLimitExceededError < Error; end
    # Raised by #complete_checkout when the platform rejects completion
    # because a line item is out of stock or otherwise unavailable —
    # design-log §16 "Stock/availability going stale": the gem re-checks by
    # surfacing the platform's own rejection rather than adding a separate
    # check_availability call agents could forget to make. Maps to UCP's
    # standardized "out_of_stock"/"item_unavailable" error codes
    # (schemas/shopping/types/error_code.json).
    class OutOfStockError < Error; end
    # Raised when a mutation collides with a concurrent write upstream (HTTP
    # 409, or a platform's own optimistic-concurrency rejection) — the
    # resource changed between this call's read and its write. Support::Retry
    # deliberately never retries this itself: the state it read is already
    # stale, so retrying blindly would just collide again. The caller is
    # expected to re-read (get_cart/get_checkout) and resubmit against
    # current state. Maps to UCP's freeform "conflict" error code —
    # error_code.json's examples list isn't exhaustive ("freeform codes are
    # permitted"); "conflict" follows the same snake_case convention as its
    # "out_of_stock"/"payment_failed" examples, same justification
    # OutOfStockError above relies on.
    class ConflictError < Error; end
    # Raised when Support::Retry exhausts its bounded backoff against a
    # genuinely-retryable upstream throttle (Shopify GraphQL THROTTLED, HTTP
    # 429, or cartSubmitForCompletion's SubmitThrottled pollAfter) and the
    # platform still hasn't done the work. Named apart from
    # RateLimitExceededError — that one is this gem's own pluggable
    # RateLimiter rejecting a call before it ever reaches the network; this
    # is the upstream platform itself refusing after every retry. Maps to
    # UCP's freeform "rate_limited" error code, same convention as
    # ConflictError above.
    class UpstreamThrottledError < Error; end

    # Raised by PolicyGuard.check! (docs/plans/agentic-payments.md Phase 2)
    # when a payment-completing dispatch fails a locally-configured guard —
    # spend cap, velocity limit, merchant allowlist, or per-token scope.
    # `reason` is a stable snake_case symbol (not just the message) so a
    # caller can branch on *why* without parsing prose, matching
    # OutOfStockError/ConflictError's freeform-error-code convention above.
    # `decision` carries the same shape PolicyGuard.check! returns on
    # success, so Dispatcher can persist "blocked, here's why" onto the
    # Phase 0 transaction record the same way it persists a passing decision.
    class PolicyViolationError < Error
      attr_reader :reason, :decision

      def initialize(message, reason:, decision:)
        super(message)
        @reason = reason
        @decision = decision
      end
    end
  end
end
