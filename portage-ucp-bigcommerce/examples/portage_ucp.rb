# frozen_string_literal: true

# Example PORTAGE_UCP_CONFIG file — copy this somewhere in your app (e.g.
# config/portage_ucp.rb), fill in the two collaborators below, then run:
#
#   PORTAGE_UCP_CONFIG=./config/portage_ucp.rb bundle exec portage-ucp-bigcommerce
#
# Everything here is the "wire a real one" side of the exe's step 2 — the
# unconfigured defaults (UnconfiguredAuthenticator, NullRateLimiter) are safe
# but reject every mutating call, so an MCP client can search/browse the
# catalog and nothing else until this runs. See README's "Security hooks"
# for what each collaborator's contract is.

# rubocop:disable Style/OneClassPerFile -- one self-contained example file on purpose

# A minimal bearer-token authenticator: the MCP client sends a static token as
# part of its `server_context` (however your transport surfaces it — e.g. an
# `Authorization` header on Streamable HTTP), and this checks it against one
# value from the environment. Swap in per-session lookup / OAuth / whatever
# your real auth story is — this is deliberately the simplest thing that
# satisfies the contract.
class StaticBearerAuthenticator < Portage::Ucp::Authenticator
  def initialize(token:)
    super()
    @token = token
  end

  def call(server_context)
    presented = server_context&.dig(:headers, "authorization")&.delete_prefix("Bearer ")
    return server_context if presented && presented == @token

    raise Portage::Ucp::AuthenticationError, "missing or invalid bearer token"
  end
end

# A minimal per-capability, per-key rate limiter using an in-process counter.
# Fine for a single-process stdio server; swap in Redis/similar once you're
# running more than one process.
class InMemoryRateLimiter < Portage::Ucp::RateLimiter
  LIMIT = 30 # mutating calls per capability, per key, per window
  WINDOW_SECONDS = 60

  def initialize
    @counts = Hash.new { |h, k| h[k] = [] }
    @mutex = Mutex.new
    super
  end

  def check!(key, capability)
    @mutex.synchronize do
      bucket = @counts[[key, capability]]
      bucket.reject! { |t| t < monotonic_now - WINDOW_SECONDS }
      raise Portage::Ucp::RateLimitExceededError, "#{capability}: rate limit exceeded" if bucket.size >= LIMIT

      bucket << monotonic_now
    end
  end

  private

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
# rubocop:enable Style/OneClassPerFile

Portage::Ucp.configure do |config|
  config.authenticator = StaticBearerAuthenticator.new(token: ENV.fetch("PORTAGE_UCP_BEARER_TOKEN"))
  config.rate_limiter = InMemoryRateLimiter.new
  config.business = { name: ENV.fetch("PORTAGE_UCP_BUSINESS_NAME", "Your Store"),
                      url: ENV.fetch("PORTAGE_UCP_BUSINESS_URL", "https://your-shop.example") }
end
