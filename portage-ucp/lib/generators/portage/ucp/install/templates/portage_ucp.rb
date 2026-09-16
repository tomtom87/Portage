Portage::Ucp.configure do |config|
  # TODO: authenticator must return an auth context (any truthy value) or
  # raise Portage::Ucp::AuthenticationError. Left unset, every mutating
  # capability call is rejected (UnconfiguredAuthenticator).
  # config.authenticator = ->(server_context) { ... }

  # TODO: rate_limiter#check!(key, capability) raises
  # Portage::Ucp::RateLimitExceededError to block a call. Left unset, no
  # limiting is applied (NullRateLimiter).
  # config.rate_limiter = MyRateLimiter.new

  # TODO: business identity advertised in the /.well-known/ucp manifest.
  # config.business = { name: "Your Business" }

  # config.signer = MySigner.new
  # config.signing_keys = []
  # config.payment_handlers = []
  # config.services = []
  # config.mandate_trusted_keys = []
  # config.require_mandate_signature = false
end
