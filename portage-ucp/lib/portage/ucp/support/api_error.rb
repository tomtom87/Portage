module Portage
  module Ucp
    module Support
      # Mixed into each adapter gem's own ApiError, which stays a subclass of
      # that gem's Error (so `rescue Portage::Ucp::Wix::Error` keeps catching
      # everything the Wix gem raises) — a module rather than a base class
      # precisely to leave that hierarchy alone.
      #
      # Carries the two things every gem's ApiError carried identically: the
      # HTTP status (which Support::NotFound#nil_on_not_found reads) and the parsed
      # body. What differs per platform is only where the human-readable
      # message lives inside that body, which is the `detail` hook.
      module ApiError
        attr_reader :status, :body

        def initialize(status, body)
          @status = status
          @body = body
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
