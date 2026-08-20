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
    # Raised by #complete_checkout when the platform rejects completion
    # because a line item is out of stock or otherwise unavailable —
    # design-log §16 "Stock/availability going stale": the gem re-checks by
    # surfacing the platform's own rejection rather than adding a separate
    # check_availability call agents could forget to make. Maps to UCP's
    # standardized "out_of_stock"/"item_unavailable" error codes
    # (schemas/shopping/types/error_code.json).
    class OutOfStockError < Error; end
  end
end
