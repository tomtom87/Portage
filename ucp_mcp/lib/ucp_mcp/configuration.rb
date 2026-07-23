require "logger"

module UcpMcp
  # Global defaults, set once via `UcpMcp.configure { |c| ... }`. Nothing
  # requires this — every collaborator can still be passed explicitly to
  # Mcp::Server.build/Manifest.new — but it's the one place a consumer wires
  # up their authenticator/rate limiter/logger without threading them
  # through every call site.
  class Configuration
    attr_accessor :registry, :authenticator, :rate_limiter, :logger,
                  :business, :signer, :payment_handlers, :signing_keys

    def initialize
      @registry = CapabilityRegistry.default
      @authenticator = UnconfiguredAuthenticator.new
      @rate_limiter = NullRateLimiter.new
      @logger = Logger.new($stdout)
      @payment_handlers = []
      @signing_keys = []
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
