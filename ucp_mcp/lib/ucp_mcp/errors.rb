module UcpMcp
  class Error < StandardError; end
  class NotImplementedError < Error; end
  class UnknownCapabilityError < Error; end
  class UnknownActionError < Error; end
  class CapabilityNotAdvertisedError < Error; end
end
