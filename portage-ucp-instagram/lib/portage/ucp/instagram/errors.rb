module Portage
  module Ucp
    module Instagram
      class Error < StandardError; end

      # Raised when a Meta Graph error body carries `error.code == 190`
      # (OAuthException: the access token is expired, revoked, or otherwise
      # invalid) — deliberately its own class rather than a flavor of
      # ApiError. No amount of retrying fixes this: the token itself needs
      # re-minting via Business Login consent and AccessTokenFetcher, not
      # another attempt at the same request, so Client#retryable_error?
      # never retries it, and — unlike ApiError — this isn't a subclass
      # ApiError itself, so an `Adapter` `rescue ApiError => e; nil if
      # e.status == 400` guard (see #get_product/#get_order) can't
      # accidentally swallow it as a plain "not found": token expiry always
      # propagates to the caller.
      class TokenExpiredError < Error
        include Portage::Ucp::Support::ApiError

        private

        def api_label = "Instagram/Graph"

        def detail(body)
          message = body.is_a?(Hash) ? body.dig("error", "message") : body
          "expired or invalid access token (code 190): #{message} — re-mint a token via Business Login " \
            "consent and Portage::Ucp::Instagram::AccessTokenFetcher; retrying this request will not help."
        end
      end

      # Meta's own platform-throttling codes — reported as a bare HTTP 400
      # with one of these `error.code` values rather than a 429, so
      # Support::Retry's default status-only check misses them entirely.
      # Client#retryable_error? consults ApiError#throttled? to catch these
      # alongside a real 429/5xx.
      THROTTLING_CODES = [4, 17, 32, 613].freeze

      # Raised for any other non-2xx response from Meta's Graph API
      # (`graph.facebook.com`) — a non-2xx status with a JSON
      # `{error: {message, type, code, error_subcode, fbtrace_id}}` body.
      class ApiError < Error
        include Portage::Ucp::Support::ApiError

        # Routes a code-190 (expired/invalid token) body to TokenExpiredError
        # instead of building an ApiError — Client#get only ever raises
        # `api_error_class.new(...)` (see Support::HttpClient#parse!), so
        # intercepting `.new` here is the one place that can redirect
        # without every caller having to inspect the body itself.
        def self.new(status, body, retry_after: nil)
          return TokenExpiredError.new(status, body, retry_after: retry_after) if meta_code(body) == 190

          super
        end

        def self.meta_code(body)
          body.dig("error", "code") if body.is_a?(Hash)
        end
        private_class_method :meta_code

        # Meta's own error taxonomy, alongside the HTTP `status` Support::
        # ApiError already carries — `error_subcode`/`fbtrace_id` are what
        # Meta support asks for when escalating a request.
        def code
          @body.dig("error", "code") if @body.is_a?(Hash)
        end

        def error_subcode
          @body.dig("error", "error_subcode") if @body.is_a?(Hash)
        end

        def fbtrace_id
          @body.dig("error", "fbtrace_id") if @body.is_a?(Hash)
        end

        # True for a real 429/5xx (same shape Support::Retry's default
        # already understands via #status) or one of Meta's own throttling
        # codes arriving as a bare 400 — Client#retryable_error? uses this
        # to hand both to Support::Retry.
        def throttled?
          status == 429 || (500..599).cover?(status) || THROTTLING_CODES.include?(code)
        end

        private

        # Not just "Instagram": the same client and errors cover Facebook
        # Shops, since both sit on one Meta Graph API surface.
        def api_label = "Instagram/Graph"

        def detail(body)
          body.dig("error", "message") || body
        end
      end
    end
  end
end
