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

      # Raised by .discover when the manifest can't be fetched at all: the URL
      # 404s, the host refuses the connection, or the body isn't valid JSON.
      # Indistinguishable from "this store doesn't run UCP" — callers that
      # want to fall back silently for that case should rescue this.
      class DiscoveryError < Error; end

      # Raised by .discover when the manifest *was* fetched and parsed as
      # JSON, but this client couldn't make sense of its shape (no `services`
      # entry advertising an `mcp` transport). Unlike DiscoveryError, this
      # means the store *is* running UCP — the failure is on this client's
      # side, not the store's — so callers shouldn't treat it the same as
      # "no native UCP support" the way a 404 does.
      class ManifestShapeError < DiscoveryError; end
    end
  end
end
