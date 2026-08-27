module Portage
  module Ucp
    module Support
      # Mixed into each adapter gem's own ApiError, which stays a subclass of
      # that gem's Error (so `rescue Portage::Ucp::Wix::Error` keeps catching
      # everything the Wix gem raises) — a module rather than a base class
      # precisely to leave that hierarchy alone.
      #
      # Carries the three things every gem's ApiError carried identically: the
      # HTTP status (which Support::NotFound#nil_on_not_found reads), the
      # parsed body, and — when the response sent one — the Retry-After
      # header Support::Retry consults to time a 429's backoff. What differs
      # per platform is only where the human-readable message lives inside
      # the body, which is the `detail` hook.
      module ApiError
        attr_reader :status, :body, :retry_after

        def initialize(status, body, retry_after: nil)
          @status = status
          @body = body
          @retry_after = retry_after
          super("#{api_label} API error (#{status}): #{detail(body)}")
        end

        private

        # Defaults to the including gem's module name — Portage::Ucp::Wix::
        # ApiError reports "Wix". Override where the API's public name isn't
        # the gem's (e.g. Instagram calls into Meta's Graph API).
        def api_label
          self.class.name.split("::")[-2]
        end

        # Override with the platform's error-body shape, e.g.
        # `body["message"] || body`.
        def detail(body)
          body
        end
      end
    end
  end
end
