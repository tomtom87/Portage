module UcpMcp
  # @abstract Pluggable rate-limit hook for mutating capabilities (§9). The
  #   gem bundles no limiter (no storage assumption) — #check! is called
  #   before every mutating tool call and must raise
  #   UcpMcp::RateLimitExceededError to block it. The default, NullRateLimiter,
  #   never limits: a consumer opts in to limiting by configuring one, same
  #   as the manifest/webhook signing story elsewhere in §9.
  class RateLimiter
    # @param key [String] a per-session/per-caller identifier the consumer
    #   derives from the MCP server_context (§9 says "per-session/per-key" —
    #   which one is up to the consumer's auth setup).
    # @param capability [String] the capability name being called, e.g.
    #   "dev.ucp.shopping.cart", so limits can be scoped per capability.
    def check!(_key, _capability)
      raise NotImplementedError, "#{self.class} must implement #check!"
    end
  end

  # The default: never limits. Present so an unconfigured server behaves
  # exactly as it did before this hook existed, rather than silently
  # blocking mutations the way UnconfiguredAuthenticator does for auth.
  class NullRateLimiter < RateLimiter
    def check!(_key, _capability); end
  end
end
