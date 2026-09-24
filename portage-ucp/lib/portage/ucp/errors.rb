module Portage
  module Ucp
    class Error < StandardError; end
    class NotImplementedError < Error; end
    class UnknownCapabilityError < Error; end
    class UnknownActionError < Error; end
    class CapabilityNotAdvertisedError < Error; end
    class AuthenticationError < Error; end
    class RawPanRejectedError < Error; end
    # Raised by PaymentEnrollmentGuard.validate! (design-log §33/Phase B)
    # when an Adapter's create_payment_enrollment/get_payment_enrollment
    # result doesn't hold the shape `PaymentEnrollment` itself never
    # enforces — value_objects.rb has no validation of any kind, same
    # raise-free posture as every other Data.define there, so this is the
    # guard's own error, not value_objects.rb's.
    class InvalidPaymentEnrollmentError < Error; end
    # Raised by Ap2::MandateGuard.validate! (design-log §33/Phase B) — a
    # mandate that's expired, missing a required field, or (when the caller
    # supplies a `trusted_keys:` trust anchor) fails cryptographic
    # verification via Ap2::MandateSignature. Shape-only vs shape+crypto is
    # the caller's choice, not this error's — see Ap2::MandateGuard's own
    # comment.
    class InvalidMandateError < Error; end
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

    # Raised by a Confirmer (docs/plans/agentic-payments.md Phase 3) when a
    # payment-completing dispatch isn't approved — explicit "n", a timeout,
    # or an async transport's own deny. Same reason/decision shape as
    # PolicyViolationError above, for the same reasons: a stable symbol to
    # branch on, and a decision Dispatcher persists onto the Phase 0
    # transaction record via `confirmation_outcome`.
    class ConfirmationDeniedError < Error
      attr_reader :reason, :decision

      def initialize(message, reason:, decision:)
        super(message)
        @reason = reason
        @decision = decision
      end
    end

    # Raised by Support::Connection (docs/plans/proxy-support.md Phase 1)
    # when any hop of a proxy connection fails — a plain-forward/gateway
    # dial that can't reach its proxy at all, or (most commonly) a
    # hand-rolled CONNECT tunnel hop answering anything but 200. Named by
    # 1-indexed hop position (never 0-indexed — "hop 2" means the second
    # proxy a request passes through, matching how a human would describe a
    # chain) and the *redacted* proxy host (`host:port`, or
    # `http://***@host:port` when the profile carried credentials) — never
    # the real credentials, same posture as `doctor`'s proxy_finding in
    # portage-cli. `status` is the CONNECT response's HTTP status when the
    # hop answered at all (e.g. 407 for "proxy authentication required"),
    # or nil when the hop never answered (DNS failure, connection refused).
    class ProxyError < Error
      attr_reader :hop_index, :status

      def initialize(hop_index:, host:, status: nil, detail: nil)
        @hop_index = hop_index
        @status = status
        super(build_message(host, detail))
      end

      private

      def build_message(host, detail)
        redacted = Support::Connection.redact(host)
        outcome = if status
                    reason = Support::Connection::REASONS[status]
                    "CONNECT failed with #{status}#{" (#{reason})" if reason}"
                  else
                    "CONNECT failed#{" (#{detail})" if detail}"
                  end
        "hop #{hop_index} (#{redacted}): #{outcome}"
      end
    end
  end
end
