module Portage
  module Ucp
    module Client
      # Base class for every error this gem raises.
      class Error < StandardError; end

      # Raised when a tool call's JSON-RPC response comes back with
      # `isError: true` — e.g. an AuthenticationError/RateLimitExceededError/
      # RawPanRejectedError the server side surfaced. `#message` is the text
      # content the server returned, not a generic string.
      class ServerError < Error; end

      # Raised by .discover when the manifest can't be fetched/parsed, or has
      # no `services` entry for the mcp transport to connect to (see
      # Portage::Ucp::Manifest#services — the core-gem fix this depends on).
      class DiscoveryError < Error; end
    end
  end
end
