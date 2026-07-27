module Portage
  module Ucp
    class Error < StandardError; end
    class NotImplementedError < Error; end
    class UnknownCapabilityError < Error; end
    class UnknownActionError < Error; end
    class CapabilityNotAdvertisedError < Error; end
    class AuthenticationError < Error; end
    class RawPanRejectedError < Error; end
    class RateLimitExceededError < Error; end
  end
end
