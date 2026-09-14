module Portage
  module Cli
    class PaymentMethods
      # Headless tier (no D-Bus session — the common case for a server-
      # deployed agent): no local storage at all, consistent with how
      # Resolver.env_for already resolves platform credentials. The token
      # *is* PORTAGE_PAYMENT_TOKEN — there's no id/enrollment/freeze/revoke
      # bookkeeping to do, since there's nowhere local to keep it.
      class EnvBackend
        VAR = "PORTAGE_PAYMENT_TOKEN".freeze

        def self.available? = true

        def read(_id) = ENV.fetch(VAR, nil)

        def write(_id, _token)
          raise NotSupportedError, "headless mode has no local storage — set #{VAR} instead"
        end

        def delete(_id)
          raise NotSupportedError, "headless mode has no local storage — unset #{VAR} instead"
        end
      end

      class NotSupportedError < StandardError; end
    end
  end
end
