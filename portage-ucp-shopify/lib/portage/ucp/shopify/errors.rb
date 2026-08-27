require "time"

module Portage
  module Ucp
    module Shopify
      class Error < StandardError; end

      # Raised when a GraphQL response carries top-level `errors` (malformed
      # query, throttled, auth rejected) — distinct from a mutation's
      # `userErrors`, which is a well-formed response describing a business
      # rejection (e.g. "line item not found").
      class GraphqlError < Error
        def initialize(errors)
          @errors = errors
          super(errors.map { |e| e["message"] }.join("; "))
        end

        # Shopify's cost-throttling reports THROTTLED as a top-level error's
        # extensions.code, not an HTTP status — Client#retryable_error? uses
        # this to hand it to Support::Retry alongside 429/5xx.
        def throttled?
          @errors.any? { |e| e.dig("extensions", "code") == "THROTTLED" }
        end
      end

      # Raised when a mutation's `userErrors` array is non-empty.
      class UserError < Error
        def initialize(field, errors)
          super("#{field} userErrors: #{errors.map { |e| e['message'] }.join('; ')}")
        end
      end

      # Raised for a bare 5xx HTTP status from either GraphQL endpoint —
      # unlike GraphqlError/UserError, there's no well-formed JSON body to
      # read a message from at this layer. Retryable by
      # Client#retryable_error?, same as any other platform's transport 5xx.
      class ServerError < Error
        attr_reader :status

        def initialize(status)
          @status = status
          super("Shopify API server error (#{status})")
        end
      end

      # Raised when cartSubmitForCompletion answers SubmitThrottled —
      # Shopify is still processing the submission and says to poll again
      # after `poll_after`. Adapter#poll_submission retries on this (see
      # Support::Retry) instead of handing an ambiguous
      # "complete_in_progress" straight back to the caller; if retries
      # exhaust while Shopify is still throttled, it's re-raised as
      # Portage::Ucp::UpstreamThrottledError.
      class SubmitThrottled < Error
        attr_reader :poll_after

        def initialize(poll_after)
          @poll_after = poll_after
          super("cartSubmitForCompletion still processing, poll after #{poll_after}")
        end

        def retry_after
          [Time.parse(poll_after) - Time.now, 0].max
        end
      end
    end
  end
end
