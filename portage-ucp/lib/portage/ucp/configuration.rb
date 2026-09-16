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
                    :idempotency_provider

      # idempotency_provider has no default set here, unlike the other
      # collaborators above — Support::Idempotency#idempotency_store falls
      # back to a fresh per-instance MemoryStore when this is unset, so
      # setting it is an opt-in to a shared/process-wide store rather than
      # a default every adapter instance would otherwise get for free.

      def initialize
        @registry = CapabilityRegistry.default
        @authenticator = UnconfiguredAuthenticator.new
        @rate_limiter = NullRateLimiter.new
        @logger = Logger.new($stdout)
        @payment_handlers = []
        @signing_keys = []
        @services = []
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
