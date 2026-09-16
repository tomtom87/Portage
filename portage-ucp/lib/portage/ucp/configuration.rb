require "logger"

module Portage
  module Ucp
    # Global defaults, set once via `Portage::Ucp.configure { |c| ... }`. Nothing
    # requires this — every collaborator can still be passed explicitly to
    # Mcp::Server.build/Manifest.new — but it's the one place a consumer wires
    # up their authenticator/rate limiter/logger without threading them
    # through every call site.
    class Configuration
      attr_accessor :registry, :authenticator, :rate_limiter, :logger,
                    :business, :signer, :payment_handlers, :signing_keys, :services,
                    :idempotency_provider, :mandate_trusted_keys, :require_mandate_signature

      # idempotency_provider has no default set here, unlike the other
      # collaborators above — Support::Idempotency#idempotency_store falls
      # back to a fresh per-instance MemoryStore when this is unset, so
      # setting it is an opt-in to a shared/process-wide store rather than
      # a default every adapter instance would otherwise get for free.

      # mandate_trusted_keys is likewise unset by default (see
      # Dispatcher's mandate_trust_keys doc / Ap2::MandateGuard) — this gem
      # has no AP2 issuer keys of its own. require_mandate_signature
      # defaults to false so an unconfigured Dispatcher keeps today's
      # shape-only posture; a caller flips it on to make MandateGuard
      # raise instead of silently skipping crypto when trusted_keys
      # resolves to nil (design-log §33 fail-closed option).

      def initialize
        @registry = CapabilityRegistry.default
        @authenticator = UnconfiguredAuthenticator.new
        @rate_limiter = NullRateLimiter.new
        @logger = Logger.new($stdout)
        @payment_handlers = []
        @signing_keys = []
        @services = []
        @require_mandate_signature = false
      end
    end

    class << self
      def configuration
        @configuration ||= Configuration.new
      end

      def configure
        yield configuration
      end
    end
  end
end
